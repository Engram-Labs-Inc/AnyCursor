# Shared by repair-cursor-update.ps1 and shortcut-guard.ps1.
#
# Cursor's installer adds "<install>\resources\app\bin" to PATH. Other Electron
# tools (VS Code forks, editors, terminals) keep directory handles on PATH
# folders, which blocks Cursor's next update when it renames "resources".
# These helpers keep "cursor" on PATH through a shim outside the install
# directory.

function Get-CursorInstallPathEntries([string]$InstallRoot) {
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
  $rootNormalized = $InstallRoot.TrimEnd("\").ToLowerInvariant()
  foreach ($entry in $entries) {
    foreach ($part in ($entry.Value -split ";")) {
      $trimmed = $part.Trim().TrimEnd("\")
      if (-not $trimmed) { continue }
      $normalized = $trimmed.ToLowerInvariant()
      if ($normalized -eq $rootNormalized -or $normalized.StartsWith($rootNormalized + "\")) {
        $found += [pscustomobject]@{ Scope = $entry.Scope; Path = $trimmed }
      }
    }
  }
  return $found
}

function Set-CursorCliShim([string]$InstallRoot, [string]$ShimDir) {
  New-Item -ItemType Directory -Force -Path $ShimDir | Out-Null
  $shim = Join-Path $ShimDir "cursor.cmd"
  $content = @"
@echo off
rem AnyCursor shim. Cursor's own installer puts its CLI inside the install
rem directory; other editors keep directory handles on PATH folders and block
rem Cursor updates. This shim keeps "cursor" on PATH without touching it.
call "$InstallRoot\resources\app\bin\cursor.cmd" %*
exit /b %ERRORLEVEL%
"@
  Set-Content -Path $shim -Value $content -Encoding ASCII

  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  if (-not $userPath) { throw "The user PATH is empty; refusing to rewrite it." }
  $rootNormalized = $InstallRoot.TrimEnd("\").ToLowerInvariant()
  $kept = @()
  $seen = @{}
  foreach ($part in ($userPath -split ";")) {
    $trimmed = $part.Trim()
    if (-not $trimmed) { continue }
    $normalized = $trimmed.TrimEnd("\").ToLowerInvariant()
    $isInstallEntry = $normalized -eq $rootNormalized -or $normalized.StartsWith($rootNormalized + "\")
    $value = if ($isInstallEntry) { $ShimDir } else { $trimmed }
    $key = $value.TrimEnd("\").ToLowerInvariant()
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    $kept += $value
  }
  $joined = $kept -join ";"
  $changed = ($joined -ne $userPath)

  if ($changed) {
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
    } catch { }
  }

  return [pscustomobject]@{ Changed = $changed; Shim = $shim }
}
