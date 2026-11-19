param([ValidateSet('run', 'fresh', 'stop')][string]$Mode = 'run')

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$data = Join-Path $env:APPDATA 'Navi Dev'

Get-Process -Name 'Navi Dev', 'Navi' -ErrorAction SilentlyContinue | Stop-Process -Force
if ($Mode -eq 'stop') {
    $installed = Join-Path $env:LOCALAPPDATA 'Navi\current\Navi.exe'
    if (Test-Path $installed) { Start-Process $installed }
    return
}
if ($Mode -eq 'fresh' -and (Test-Path $data)) { Remove-Item -Recurse -Force $data }

dotnet build (Join-Path $root 'App/App.csproj') -c Debug
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Start-Process (Join-Path $root 'App/bin/Debug/net10.0-windows/Navi Dev.exe')
