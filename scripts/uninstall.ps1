param(
  [string]$TaskName = "AnyCursor Gateway",
  [switch]$RemoveData
)

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent

$taskNames = @($TaskName, 'AnyCursor Gateway Watchdog', 'AnyCursor Shortcut Guard')
foreach ($name in $taskNames) {
  $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
  if ($task) {
    Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $name -Confirm:$false
    Write-Host "Removed scheduled task '$name'." -ForegroundColor Green
  } else {
    Write-Host "Scheduled task '$name' was not registered." -ForegroundColor Yellow
  }
}

$watchProcesses = Get-CimInstance Win32_Process -Filter "Name='AnyCursor Gateway.exe'" -ErrorAction SilentlyContinue
foreach ($watchProcess in $watchProcesses) {
  Stop-Process -Id $watchProcess.ProcessId -Force -ErrorAction SilentlyContinue
  Write-Host "Stopped the gateway supervisor ($($watchProcess.ProcessId))." -ForegroundColor Green
}

$startupEntries = @(
  (Join-Path ([Environment]::GetFolderPath('Startup')) 'AnyCursor Gateway.lnk'),
  (Join-Path ([Environment]::GetFolderPath('Startup')) 'AnyCursor Gateway.vbs'),
  (Join-Path $env:LOCALAPPDATA 'AnyCursor\gateway-start.vbs'),
  (Join-Path $env:LOCALAPPDATA 'AnyCursor\AnyCursor.exe'),
  (Join-Path $env:LOCALAPPDATA 'AnyCursor\AnyCursor Gateway.exe'),
  (Join-Path $env:LOCALAPPDATA 'AnyCursor\AnyCursorLauncher.cs')
)
foreach ($entry in $startupEntries) {
  if (Test-Path $entry) {
    Remove-Item $entry -Force
    Write-Host "Removed startup entry '$entry'." -ForegroundColor Green
  }
}

$binDir = Join-Path $env:LOCALAPPDATA 'AnyCursor\bin'
$shimExists = Test-Path (Join-Path $binDir 'cursor.cmd')
if (Test-Path $binDir) {
  Remove-Item $binDir -Recurse -Force -ErrorAction SilentlyContinue
  Write-Host "Removed the shortcut guard scripts." -ForegroundColor Green
}

# repair-cursor-update.ps1 can move the Cursor CLI out of its install directory
# so PATH handles cannot block Cursor updates. Put Cursor's own entry back
# before the shim disappears, otherwise "cursor" stops resolving.
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath -and $shimExists) {
  $parts = @($userPath -split ';' | Where-Object { $_ -and $_.Trim() })
  $shimIndex = -1
  for ($i = 0; $i -lt $parts.Count; $i++) {
    if ($parts[$i].Trim().TrimEnd('\') -ieq $binDir.TrimEnd('\')) { $shimIndex = $i; break }
  }
  if ($shimIndex -ge 0) {
    $cursorBin = Join-Path $env:LOCALAPPDATA 'Programs\cursor\resources\app\bin'
    if (Test-Path $cursorBin) {
      $parts[$shimIndex] = $cursorBin
    } else {
      $parts = @($parts | Where-Object { $_.Trim().TrimEnd('\') -ine $binDir.TrimEnd('\') })
    }
    try {
      $registry = Get-Item 'HKCU:\Environment'
      $kind = $registry.GetValueKind('Path')
      Set-ItemProperty -Path 'HKCU:\Environment' -Name 'Path' -Value ($parts -join ';') -Type $kind
      Write-Host "Restored the Cursor CLI PATH entry." -ForegroundColor Green
    } catch {
      Write-Host "Could not restore the Cursor CLI PATH entry; check your user PATH." -ForegroundColor Yellow
    }
  }
}

$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
if (Test-Path $hostsPath) {
  $hostsText = Get-Content $hostsPath -Raw -ErrorAction SilentlyContinue
  if ($hostsText -and $hostsText.Contains('# BEGIN AnyCursor telemetry block')) {
    Write-Host "The optional telemetry hosts block is still present. Remove it with scripts\privacy.ps1 -Disable (administrator)." -ForegroundColor Yellow
  }
}

$gateways = Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -match 'gateway[\\/]index\.js' -and $_.CommandLine -match 'anycursor' }
foreach ($gateway in $gateways) {
  Stop-Process -Id $gateway.ProcessId -Force -ErrorAction SilentlyContinue
  Write-Host "Stopped gateway process $($gateway.ProcessId)." -ForegroundColor Green
}

$cliCandidates = @(
  (Join-Path $env:LOCALAPPDATA "Programs\cursor\resources\app\bin\cursor.cmd"),
  (Join-Path $env:LOCALAPPDATA "Programs\cursor\resources\app\bin\cursor.exe")
)
$cli = $cliCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $cli) {
  $cmd = Get-Command cursor -ErrorAction SilentlyContinue
  if ($cmd) { $cli = $cmd.Source }
}
if ($cli) {
  & $cli --uninstall-extension anycursor.anycursor 2>$null
  if ($LASTEXITCODE -eq 0) {
    Write-Host "Uninstalled the AnyCursor extension." -ForegroundColor Green
  } else {
    Write-Warning "The extension was not installed or could not be removed."
  }
} else {
  Write-Warning "Cursor CLI not found; remove the AnyCursor extension from Cursor manually."
}

$extRoot = Join-Path $env:USERPROFILE ".cursor\extensions"
if (Test-Path $extRoot) {
  Get-ChildItem $extRoot -Directory -Filter "anycursor.anycursor-*" -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Removed extension directory $($_.FullName)." -ForegroundColor Green
  }
}

& (Join-Path $PSScriptRoot "repair-shortcuts.ps1") -Undo

if ($RemoveData) {
  $localDir = Join-Path $env:LOCALAPPDATA "AnyCursor"
  if (Test-Path $localDir) {
    $answer = Read-Host "Delete $localDir including config and logs? Type YES to confirm"
    if ($answer -eq "YES") {
      Remove-Item $localDir -Recurse -Force
      Write-Host "Removed $localDir" -ForegroundColor Green
    } else {
      Write-Host "Kept $localDir" -ForegroundColor Yellow
    }
  }
} else {
  Write-Host "Kept your config and logs in $env:LOCALAPPDATA\AnyCursor." -ForegroundColor Yellow
}

Write-Host "Uninstall complete. Cursor will use its native backend after restart." -ForegroundColor Green
