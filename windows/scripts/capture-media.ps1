param([string]$Out = (Join-Path (Get-Location) 'media'))

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms, System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class NaviInput
{
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
    [DllImport("user32.dll")] public static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
    public static void Click() { mouse_event(0x02, 0, 0, 0, UIntPtr.Zero); mouse_event(0x04, 0, 0, 0, UIntPtr.Zero); }
    public static void Chord(byte[] keys)
    {
        foreach (var k in keys) keybd_event(k, 0, 0, UIntPtr.Zero);
        Array.Reverse(keys);
        foreach (var k in keys) keybd_event(k, 0, 2, UIntPtr.Zero);
    }
}
'@

$root = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $root 'App/bin/Release/net10.0-windows/Navi.exe'
if (-not (Test-Path $exe)) { throw "Build Release first: $exe is missing" }
New-Item -ItemType Directory -Force $Out | Out-Null
$data = Join-Path $env:APPDATA 'Navi'
if (Test-Path $data) { Remove-Item -Recurse -Force $data }

function Shot([string]$name) {
    Start-Sleep -Milliseconds 400
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
    $bitmap.Save((Join-Path $Out "$name.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    $graphics.Dispose()
    $bitmap.Dispose()
    Write-Host "Saved $name.png"
}

function Glide([int]$x, [int]$y) {
    $from = [System.Windows.Forms.Cursor]::Position
    foreach ($step in 1..20) {
        $t = $step / 20
        [NaviInput]::SetCursorPos([int]($from.X + ($x - $from.X) * $t), [int]($from.Y + ($y - $from.Y) * $t)) | Out-Null
        Start-Sleep -Milliseconds 15
    }
    Start-Sleep -Milliseconds 250
}

function Find([string]$name) {
    $condition = New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::NameProperty), $name
    foreach ($try in 1..30) {
        $found = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
        if ($found) { return $found.Current.BoundingRectangle }
        Start-Sleep -Milliseconds 200
    }
    throw "Could not find '$name' on screen"
}

function ClickRow([string]$name, [int]$offset = 0) {
    $rect = Find $name
    Glide ([int]($rect.X + $rect.Width / 2 + $offset)) ([int]($rect.Y + $rect.Height / 2))
    [NaviInput]::Click()
}

function CloseDialog([string]$title) {
    $condition = New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::NameProperty), $title
    $window = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children, $condition)
    if (-not $window) { return }
    $window.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close()
}

CloseDialog 'System Properties'
(New-Object -ComObject Shell.Application).MinimizeAll()
Start-Sleep -Seconds 1
$recording = $null
$ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
if ($ffmpeg) {
    $info = New-Object System.Diagnostics.ProcessStartInfo $ffmpeg.Source
    $info.Arguments = "-y -loglevel error -f gdigrab -framerate 30 -draw_mouse 1 -i desktop -c:v libx264 -preset veryfast -pix_fmt yuv420p `"$(Join-Path $Out 'navi-windows.mp4')`""
    $info.UseShellExecute = $false
    $info.RedirectStandardInput = $true
    $recording = [System.Diagnostics.Process]::Start($info)
    Start-Sleep -Seconds 2
}

$app = Start-Process $exe -PassThru
try {
    Start-Sleep -Seconds 3
    if ($app.HasExited) { throw "Navi quit at launch with code $($app.ExitCode)" }
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    Glide ([int]($screen.Width * 0.62)) ([int]($screen.Height * 0.8))
    [NaviInput]::Chord([byte[]](0x11, 0x12, 0x10, 0x4E))
    Find 'Quit Navi' | Out-Null
    Shot 'menu'
    ClickRow "Settings$([char]0x2026)"
    Find 'Talk to Type' | Out-Null
    Shot 'settings'
    ClickRow 'Edit Screenshots Before Copying'
    Start-Sleep -Milliseconds 600
    ClickRow 'Shortcut Style'
    Start-Sleep -Milliseconds 600
    Shot 'settings-changed'
    Get-Content (Join-Path $data 'settings.json') | Write-Host
    [NaviInput]::Chord([byte[]](0x1B))
    Start-Sleep -Seconds 1
    [NaviInput]::Chord([byte[]](0x11, 0x12, 0x10, 0x4E))
    Find 'Ctrl+Shift+4' | Out-Null
    Shot 'menu-mac-style'
    [NaviInput]::Chord([byte[]](0x1B))
    Start-Sleep -Seconds 1
}
finally {
    if ($recording) {
        Start-Sleep -Seconds 1
        $recording.StandardInput.Write('q')
        $recording.StandardInput.Close()
        if (-not $recording.WaitForExit(15000)) { Stop-Process -Id $recording.Id -Force }
    }
    if (-not $app.HasExited) { Stop-Process -Id $app.Id -Force }
}
