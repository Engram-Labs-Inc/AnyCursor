param(
  [switch]$Force,
  [switch]$NoLaunch,
  [switch]$Promote,
  [switch]$FixCliPath,
  [switch]$ReportOnly
)

# Recovers from a stuck Cursor update where the updater cannot rename
# "resources" because another process holds a directory handle inside the
# install directory.
#
# Two failure modes are handled:
#   1. A PATH entry points inside the install directory. Cursor's own installer
#      adds "<install>\resources\app\bin" to PATH, and other Electron tools
#      (VS Code forks, editors, terminals) keep directory handles on PATH
#      folders. That handle blocks the "resources" rename. -FixCliPath installs
#      a "cursor" shim outside the install directory and points PATH at it.
#   2. The updater already staged the new version in "<install>\_" but failed
#      while promoting it. -Promote copies the verified staged files over the
#      install without renaming "resources", which works even while a foreign
#      process holds the directory.
#
# This does not patch Cursor and does not delete user data. It closes Cursor,
# ends leftover Cursor/installer processes, promotes a staged update, repairs
# the CLI PATH entry and optionally relaunches Cursor.

$ErrorActionPreference = "Stop"
$root = Join-Path $env:LOCALAPPDATA "Programs\cursor"
$exe = Join-Path $root "Cursor.exe"
$stagedRoot = Join-Path $root "_"
$backupRoot = Join-Path $root "_bak"
$shimDir = Join-Path $env:LOCALAPPDATA "AnyCursor\bin"
$supervisor = Join-Path $env:APPDATA "Cursor\update-supervisor\win32"

function Get-ProductVersion([string]$path) {
  if (-not (Test-Path $path)) { return "" }
  $value = (Get-Item $path -ErrorAction SilentlyContinue).VersionInfo.ProductVersion
  if ($value) { return $value }
  return ""
}

function Compare-VersionText([string]$left, [string]$right) {
  $a = $null
  $b = $null
  if (-not [version]::TryParse($left, [ref]$a)) { return $null }
  if (-not [version]::TryParse($right, [ref]$b)) { return $null }
  return $a.CompareTo($b)
}

function Get-AppVersion([string]$installRoot) {
  $package = Join-Path $installRoot "resources\app\package.json"
  if (-not (Test-Path $package)) { return "" }
  try {
    return (Get-Content $package -Raw | ConvertFrom-Json).version
  } catch {
    return ""
  }
}

function Get-InstallPathEntries {
  $entries = @()
  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  if ($userPath) {
    $entries += [pscustomobject]@{ Scope = "user"; Value = $userPath }
  }
  $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
  if ($machinePath) {
    $entries += [pscustomobject]@{ Scope = "machine"; Value = $machinePath }
  }
  $found = @()
  foreach ($entry in $entries) {
    foreach ($part in ($entry.Value -split ";")) {
      $trimmed = $part.Trim().TrimEnd("\")
      if (-not $trimmed) { continue }
      $normalized = $trimmed.ToLowerInvariant()
      $rootNormalized = $root.TrimEnd("\").ToLowerInvariant()
      if ($normalized -eq $rootNormalized -or $normalized.StartsWith($rootNormalized + "\")) {
        $found += [pscustomobject]@{ Scope = $entry.Scope; Path = $trimmed }
      }
    }
  }
  return $found
}

function Confirm-Action([string]$question) {
  if ($Force) { return $true }
  $answer = Read-Host "$question [y/N]"
  return ($answer -eq "y" -or $answer -eq "Y" -or $answer -eq "yes")
}

function Stop-CursorProcesses {
  $main = Get-Process -Name Cursor -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 }
  foreach ($process in $main) {
    try { $process.CloseMainWindow() | Out-Null } catch { }
  }
  if ($main) {
    Write-Host "Waiting for Cursor to close..."
    Start-Sleep -Seconds 10
  }

  $remaining = @(Get-Process -Name Cursor -ErrorAction SilentlyContinue)
  if ($remaining) {
    Write-Host "Stopping $($remaining.Count) remaining Cursor process(es)..." -ForegroundColor Yellow
    foreach ($process in $remaining) {
      try { Stop-Process -Id $process.Id -Force -ErrorAction Stop } catch { }
    }
    Start-Sleep -Seconds 3
  }

  $left = @(Get-Process -Name Cursor -ErrorAction SilentlyContinue)
  if ($left) {
    throw "Cursor processes are still running: $($left.Id -join ', ')"
  }
  Write-Host "Cursor processes: none." -ForegroundColor Green
}

function Stop-StuckInstallers {
  $stuck = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -match '^(inno_updater|unins000|CodeSetup|is-)'
  })
  if (-not $stuck) {
    Write-Host "Updater/installer processes: none." -ForegroundColor Green
    return
  }
  foreach ($process in $stuck) {
    Write-Host "Stopping stuck $($process.Name) (pid $($process.ProcessId))..." -ForegroundColor Yellow
    try { Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop } catch { }
  }
  Start-Sleep -Seconds 3
}

function Test-StagedUpdate {
  $stagedExe = Join-Path $stagedRoot "Cursor.exe"
  if (-not (Test-Path $stagedExe)) {
    throw "The staged update has no Cursor.exe: $stagedRoot"
  }
  $signature = Get-AuthenticodeSignature $stagedExe
  if ($signature.Status -ne "Valid") {
    throw "The staged Cursor.exe signature is not valid ($($signature.Status)). Run the official Cursor installer instead."
  }
  if (Test-Path $exe) {
    $installedSignature = Get-AuthenticodeSignature $exe
    if ($installedSignature.Status -eq "Valid" -and $signature.SignerCertificate -and $installedSignature.SignerCertificate) {
      if ($signature.SignerCertificate.Thumbprint -ne $installedSignature.SignerCertificate.Thumbprint) {
        throw "The staged Cursor.exe was signed by a different publisher. Refusing to promote it."
      }
    }
  } elseif (-not ($signature.SignerCertificate.Subject -match "Anysphere")) {
    throw "The staged Cursor.exe is not signed by Anysphere. Refusing to promote it."
  }

  $stagedVersion = Get-ProductVersion $stagedExe
  if (-not $stagedVersion) {
    throw "The staged Cursor.exe has no product version."
  }
  $stagedAppVersion = Get-AppVersion $stagedRoot
  if (-not $stagedAppVersion -or $stagedAppVersion -ne $stagedVersion) {
    throw "The staged app version ($stagedAppVersion) does not match the staged Cursor.exe ($stagedVersion)."
  }
  foreach ($marker in @("resources\app\out\main.js", "resources\app\product.json", "resources\app\bin\cursor.cmd")) {
    if (-not (Test-Path (Join-Path $stagedRoot $marker))) {
      throw "The staged update is incomplete (missing $marker)."
    }
  }
  return $stagedVersion
}

function Invoke-StagedPromotion([string]$stagedVersion) {
  $log = Join-Path $env:TEMP "cursor-staged-promotion.log"
  Remove-Item $log -Force -ErrorAction SilentlyContinue
  Write-Host "Promoting staged Cursor $stagedVersion over the install directory..." -ForegroundColor Yellow
  $arguments = @($stagedRoot, $root, "/E", "/R:2", "/W:1", "/NFL", "/NDL", "/NJH", "/NJS", "/NP", "/LOG:`"$log`"")
  $robocopy = Start-Process -FilePath (Join-Path $env:SystemRoot "System32\robocopy.exe") -ArgumentList $arguments -Wait -PassThru -NoNewWindow
  if ($robocopy.ExitCode -ge 8) {
    if (Test-Path $log) { Get-Content $log -Tail 20 | ForEach-Object { Write-Host "  $_" } }
    throw "Copying the staged update failed (robocopy exit $($robocopy.ExitCode)). See $log"
  }

  $installedAfter = Get-ProductVersion $exe
  $appAfter = Get-AppVersion $root
  if ($installedAfter -ne $stagedVersion -or $appAfter -ne $stagedVersion) {
    throw "Promotion finished but the install reports $installedAfter / $appAfter instead of $stagedVersion."
  }
  Write-Host "Cursor $stagedVersion is installed." -ForegroundColor Green
}

function Clear-FailedUpdateState {
  if (-not (Test-Path $supervisor)) { return }
  $active = Join-Path $supervisor "active.json"
  if (Test-Path $active) {
    Remove-Item $active -Force -ErrorAction SilentlyContinue
    Write-Host "Cleared the stale update-supervisor request." -ForegroundColor Green
  }
  foreach ($dir in @(Get-ChildItem $supervisor -Directory -ErrorAction SilentlyContinue)) {
    $state = Join-Path $dir.FullName "state.json"
    if (-not (Test-Path $state)) { continue }
    $stage = ""
    try { $stage = (Get-Content $state -Raw | ConvertFrom-Json).stage } catch { }
    if ($stage -match "fail|error|staging|backing") {
      Remove-Item $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue
      Write-Host "Cleared update-supervisor state '$stage'." -ForegroundColor Green
    }
  }
}

function Set-CliShimPath {
  New-Item -ItemType Directory -Force -Path $shimDir | Out-Null
  $shim = Join-Path $shimDir "cursor.cmd"
  $content = @"
@echo off
rem AnyCursor shim. Cursor's own installer puts its CLI inside the install
rem directory; other editors keep directory handles on PATH folders and block
rem Cursor updates. This shim keeps "cursor" on PATH without touching it.
call "%LOCALAPPDATA%\Programs\cursor\resources\app\bin\cursor.cmd" %*
exit /b %ERRORLEVEL%
"@
  Set-Content -Path $shim -Value $content -Encoding ASCII

  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  if (-not $userPath) { throw "The user PATH is empty; refusing to rewrite it." }
  $kept = @()
  $seen = @{}
  foreach ($part in ($userPath -split ";")) {
    $trimmed = $part.Trim()
    if (-not $trimmed) { continue }
    $normalized = $trimmed.TrimEnd("\").ToLowerInvariant()
    $rootNormalized = $root.TrimEnd("\").ToLowerInvariant()
    $isInstallEntry = $normalized -eq $rootNormalized -or $normalized.StartsWith($rootNormalized + "\")
    $value = if ($isInstallEntry) { $shimDir } else { $trimmed }
    $key = $value.TrimEnd("\").ToLowerInvariant()
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    $kept += $value
  }
  $joined = $kept -join ";"

  $registry = Get-Item "HKCU:\Environment"
  $kind = $registry.GetValueKind("Path")
  Set-ItemProperty -Path "HKCU:\Environment" -Name "Path" -Value $joined -Type $kind
  $env:Path = [Environment]::GetEnvironmentVariable("Path", "User") + ";" + [Environment]::GetEnvironmentVariable("Path", "Machine")

  try {
    Add-Type -Namespace AnyCursor -Name NativeMethods -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Auto)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint Msg, System.UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out System.UIntPtr lpdwResult);
"@ -ErrorAction Stop
    $result = [UIntPtr]::Zero
    [AnyCursor.NativeMethods]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, "Environment", 2, 5000, [ref]$result) | Out-Null
  } catch {
    Write-Host "Restart Explorer or sign out for the PATH change to reach new processes." -ForegroundColor Yellow
  }

  Write-Host "cursor CLI shim: $shim" -ForegroundColor Green
  Write-Host "PATH now points at $shimDir instead of the install directory." -ForegroundColor Green
  Write-Host "Restart editors and terminals so they drop the old directory handle." -ForegroundColor Yellow
}

$installed = Get-ProductVersion $exe
$stagedVersion = ""
if (Test-Path $stagedRoot) {
  try { $stagedVersion = Get-ProductVersion (Join-Path $stagedRoot "Cursor.exe") } catch { }
}
$pathEntries = @(Get-InstallPathEntries)

if ($ReportOnly) {
  Write-Host "Install directory: $root"
  Write-Host "Installed Cursor:  $(if ($installed) { $installed } else { 'missing' })"
  Write-Host "Staged update:     $(if (Test-Path $stagedRoot) { if ($stagedVersion) { $stagedVersion } else { 'present, unreadable' } } else { 'none' })"
  Write-Host "Backup:            $(if (Test-Path $backupRoot) { 'present' } else { 'none' })"
  if ($pathEntries.Count -gt 0) {
    Write-Host "PATH entries inside the install directory:" -ForegroundColor Yellow
    foreach ($entry in $pathEntries) { Write-Host "  [$($entry.Scope)] $($entry.Path)" -ForegroundColor Yellow }
  } else {
    Write-Host "PATH entries inside the install directory: none." -ForegroundColor Green
  }
  exit 0
}

if (-not $Force) {
  Write-Host "This will close every Cursor window and end leftover Cursor," -ForegroundColor Yellow
  Write-Host "CodeSetup and inno_updater processes. Save your work first." -ForegroundColor Yellow
  $answer = Read-Host "Type YES to continue"
  if ($answer -ne "YES") {
    Write-Host "Cancelled." -ForegroundColor Yellow
    exit 1
  }
}

Stop-CursorProcesses
Stop-StuckInstallers

Write-Host ""
Write-Host "Installed Cursor: $(if ($installed) { $installed } else { 'missing' })"
Write-Host "Staged update:    $(if (Test-Path $stagedRoot) { if ($stagedVersion) { $stagedVersion } else { 'present' } } else { 'none' })"
Write-Host "Backup:           $(if (Test-Path $backupRoot) { 'present' } else { 'none' })"

if (-not $installed) {
  Write-Host ""
  Write-Host "Cursor.exe is missing from the install directory." -ForegroundColor Yellow
  Write-Host "Run the official Cursor installer once to repair the application." -ForegroundColor Yellow
  exit 2
}

if ($pathEntries.Count -gt 0) {
  Write-Host ""
  Write-Host "PATH points inside the Cursor install directory:" -ForegroundColor Yellow
  foreach ($entry in $pathEntries) { Write-Host "  [$($entry.Scope)] $($entry.Path)" -ForegroundColor Yellow }
  Write-Host "Other editors keep directory handles on PATH folders, which blocks the" -ForegroundColor Yellow
  Write-Host "'resources' rename and makes every Cursor update fail." -ForegroundColor Yellow
  $machineEntries = @($pathEntries | Where-Object { $_.Scope -eq "machine" })
  if ($machineEntries.Count -gt 0) {
    Write-Host "Machine-wide entries need an administrator; remove them by hand." -ForegroundColor Yellow
  }
  if ($FixCliPath -or (Confirm-Action "Move the cursor CLI to $shimDir and update the user PATH?")) {
    Set-CliShimPath
  }
}

if (Test-Path $stagedRoot) {
  Write-Host ""
  try {
    $verified = Test-StagedUpdate
  } catch {
    Write-Host $_.Exception.Message -ForegroundColor Yellow
    $verified = ""
  }
  if ($verified) {
    $comparison = Compare-VersionText $verified $installed
    if ($null -eq $comparison) {
      Write-Host "Could not compare staged $verified with installed $installed; leaving the staging folder alone." -ForegroundColor Yellow
    } elseif ($comparison -gt 0) {
      if ($Promote -or (Confirm-Action "Promote staged Cursor $verified over $installed in place?")) {
        Invoke-StagedPromotion $verified
        Remove-Item $stagedRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $backupRoot -Recurse -Force -ErrorAction SilentlyContinue
        Clear-FailedUpdateState
      }
    } elseif ($comparison -eq 0) {
      Write-Host "Staged files match the installed version; removing the leftovers." -ForegroundColor Green
      Remove-Item $stagedRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item $backupRoot -Recurse -Force -ErrorAction SilentlyContinue
      Clear-FailedUpdateState
    } else {
      Write-Host "Staged Cursor $verified is older than the installed $installed; removing it." -ForegroundColor Green
      Remove-Item $stagedRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item $backupRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

if (-not $NoLaunch) {
  $shortcut = Join-Path ([Environment]::GetFolderPath("Desktop")) "Cursor.lnk"
  if (Test-Path $shortcut) {
    Write-Host "Launching Cursor from the Desktop shortcut..."
    Start-Process -FilePath $shortcut
  } else {
    Write-Host "Launching Cursor..."
    Start-Process -FilePath $exe
  }
}

Write-Host ""
Write-Host "Repair complete. If the update still fails, run the official Cursor installer." -ForegroundColor Green
exit 0
