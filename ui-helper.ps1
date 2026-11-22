param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("submit", "dismiss", "minimize", "probe", "filltest", "inspect", "selectdate", "verifydate")]
    [string]$Action,
    [string]$StartTime = "",
    [string]$EndTime = "",
    [string]$Day = "",
    [Parameter(Mandatory=$true)]
    [string]$ResultFile
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class EzWinLite {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [StructLayout(LayoutKind.Sequential)] public struct RECT {
        public int Left, Top, Right, Bottom;
    }
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lp);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int max);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int command);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint attach, uint attachTo, bool value);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint mapType);
    [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern void SwitchToThisWindow(IntPtr hWnd, bool altTab);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
}
'@

$script:ToolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:TargetPid = 0

function Write-Result([string]$Value) {
    Set-Content -LiteralPath $ResultFile -Value $Value -Encoding UTF8
}

function Get-WindowRect([IntPtr]$Handle) {
    $rect = [EzWinLite+RECT]::new()
    if (-not [EzWinLite]::GetWindowRect($Handle, [ref]$rect)) {
        throw "Unable to read window rectangle."
    }
    return [pscustomobject]@{
        Handle = $Handle
        Left = $rect.Left
        Top = $rect.Top
        Width = $rect.Right - $rect.Left
        Height = $rect.Bottom - $rect.Top
    }
}

function Get-TargetWindow {
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $script:mainWindow = $null
        $script:mainWindowArea = 0
        $script:TargetPid = 0
        [EzWinLite]::EnumWindows({
            param($Handle, $Unused)
            $windowPid = [uint32]0
            [void][EzWinLite]::GetWindowThreadProcessId($Handle, [ref]$windowPid)
            $length = [EzWinLite]::GetWindowTextLength($Handle)
            if ($length -eq 0) {
                return $true
            }
            $title = [Text.StringBuilder]::new($length + 1)
            [void][EzWinLite]::GetWindowText($Handle, $title, $title.Capacity)
            if ($title.ToString().Trim() -ne "Ezviz Studio") {
                return $true
            }
            $rect = [EzWinLite+RECT]::new()
            [void][EzWinLite]::GetWindowRect($Handle, [ref]$rect)
            $width = $rect.Right - $rect.Left
            $height = $rect.Bottom - $rect.Top
            $area = $width * $height
            if ($area -le $script:mainWindowArea) {
                return $true
            }
            $script:TargetPid = [int]$windowPid
            $script:mainWindow = $Handle
            $script:mainWindowArea = $area
            return $true
        }, [IntPtr]::Zero) | Out-Null
        if ($script:mainWindow) {
            [void][EzWinLite]::ShowWindow($script:mainWindow, 9)
            Start-Sleep -Milliseconds 180
            $rect = Get-WindowRect $script:mainWindow
            if ($rect.Width -gt 700 -and $rect.Height -gt 500) {
                return $rect
            }
        }
        Start-Sleep -Milliseconds 150
    }
    throw "Ezviz Studio window not found. Open the client and log in first."
}

function Focus-Window([IntPtr]$Handle) {
    $foreground = [EzWinLite]::GetForegroundWindow()
    $foregroundPid = [uint32]0
    $targetPid = [uint32]0
    $foregroundThread = [EzWinLite]::GetWindowThreadProcessId($foreground, [ref]$foregroundPid)
    $targetThread = [EzWinLite]::GetWindowThreadProcessId($Handle, [ref]$targetPid)
    $currentThread = [EzWinLite]::GetCurrentThreadId()
    $attachedForeground = $false
    $attachedTarget = $false
    try {
        if ($foregroundThread -ne 0 -and $foregroundThread -ne $currentThread) {
            $attachedForeground = [EzWinLite]::AttachThreadInput($currentThread, $foregroundThread, $true)
        }
        if ($targetThread -ne 0 -and $targetThread -ne $currentThread) {
            $attachedTarget = [EzWinLite]::AttachThreadInput($currentThread, $targetThread, $true)
        }
        [void][EzWinLite]::ShowWindow($Handle, 9)
        [void][EzWinLite]::BringWindowToTop($Handle)
        [void][EzWinLite]::SwitchToThisWindow($Handle, $true)
        [void][EzWinLite]::SetForegroundWindow($Handle)
        [void][EzWinLite]::SetFocus($Handle)
        Start-Sleep -Milliseconds 220
        [void][EzWinLite]::SetWindowPos($Handle, [IntPtr](-2), 0, 0, 0, 0, 0x0043)
    }
    finally {
        if ($attachedTarget) {
            [void][EzWinLite]::AttachThreadInput($currentThread, $targetThread, $false)
        }
        if ($attachedForeground) {
            [void][EzWinLite]::AttachThreadInput($currentThread, $foregroundThread, $false)
        }
    }
}

function Click-At([int]$X, [int]$Y) {
    [void][EzWinLite]::SetCursorPos($X, $Y)
    Start-Sleep -Milliseconds 90
    [EzWinLite]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 70
    [EzWinLite]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
}

function Get-DownloadDialog {
    $script:downloadDialog = $null
    [EzWinLite]::EnumWindows({
        param($Handle, $Unused)
        $windowPid = [uint32]0
        [void][EzWinLite]::GetWindowThreadProcessId($Handle, [ref]$windowPid)
        if ($windowPid -ne $script:TargetPid -or -not [EzWinLite]::IsWindowVisible($Handle)) {
            return $true
        }
        $length = [EzWinLite]::GetWindowTextLength($Handle)
        if ($length -eq 0) {
            return $true
        }
        $title = [Text.StringBuilder]::new($length + 1)
        [void][EzWinLite]::GetWindowText($Handle, $title, $title.Capacity)
        if ($title.ToString() -ne "Dialog") {
            return $true
        }
        $rect = [EzWinLite+RECT]::new()
        [void][EzWinLite]::GetWindowRect($Handle, [ref]$rect)
        $width = $rect.Right - $rect.Left
        $height = $rect.Bottom - $rect.Top
        if ($width -ge 400 -and $width -le 600 -and $height -ge 240 -and $height -le 420) {
            $script:downloadDialog = [pscustomobject]@{
                Handle = $Handle
                Left = $rect.Left
                Top = $rect.Top
                Width = $width
                Height = $height
            }
            return $false
        }
        return $true
    }, [IntPtr]::Zero) | Out-Null
    return $script:downloadDialog
}

function Close-DownloadDialog {
    $dialog = Get-DownloadDialog
    if (-not $dialog) {
        return
    }
    Focus-Window $dialog.Handle
    Click-At ($dialog.Left + $dialog.Width - 20) ($dialog.Top + 22)
    Start-Sleep -Milliseconds 350
}

function Open-DownloadDialog([object]$MainWindow) {
    $dialog = Get-DownloadDialog
    if ($dialog) {
        return $dialog
    }
    Focus-Window $MainWindow.Handle
    $attempts = @(
        @(($MainWindow.Left + $MainWindow.Width - 95), ($MainWindow.Top + $MainWindow.Height - 82)),
        @(($MainWindow.Left + $MainWindow.Width - 82), ($MainWindow.Top + $MainWindow.Height - 82)),
        @(($MainWindow.Left + $MainWindow.Width - 108), ($MainWindow.Top + $MainWindow.Height - 82))
    )
    foreach ($point in $attempts) {
        Click-At $point[0] $point[1]
        for ($wait = 0; $wait -lt 15; $wait++) {
            Start-Sleep -Milliseconds 80
            $dialog = Get-DownloadDialog
            if ($dialog) {
                return $dialog
            }
        }
    }
    throw "Download dialog did not open."
}

function Invoke-CtrlKey([byte]$VirtualKey) {
    $ctrlScan = [EzWinLite]::MapVirtualKey(0x11, 0)
    $keyScan = [EzWinLite]::MapVirtualKey($VirtualKey, 0)
    [EzWinLite]::keybd_event(0x11, [byte]$ctrlScan, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 45
    [EzWinLite]::keybd_event($VirtualKey, [byte]$keyScan, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 55
    [EzWinLite]::keybd_event($VirtualKey, [byte]$keyScan, 2, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 35
    [EzWinLite]::keybd_event(0x11, [byte]$ctrlScan, 2, [UIntPtr]::Zero)
}

function Set-ClipboardText([string]$Value) {
    for ($attempt = 0; $attempt -lt 8; $attempt++) {
        try {
            [Windows.Forms.Clipboard]::SetText($Value)
            return
        }
        catch {
            if ($attempt -eq 7) {
                throw
            }
            Start-Sleep -Milliseconds 120
        }
    }
}

function Fill-TimeField([int]$X, [int]$Y, [string]$Expected) {
    Click-At $X $Y
    Start-Sleep -Milliseconds 250
    Set-ClipboardText $Expected
    Invoke-CtrlKey 0x41
    Start-Sleep -Milliseconds 100
    Invoke-CtrlKey 0x56
    Start-Sleep -Milliseconds 350
    Set-ClipboardText "__EZVIZ_READBACK_MISSING__"
    Invoke-CtrlKey 0x41
    Start-Sleep -Milliseconds 80
    Invoke-CtrlKey 0x43
    Start-Sleep -Milliseconds 220
    $actual = ""
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try {
            $actual = ([Windows.Forms.Clipboard]::GetText()).Trim()
            break
        }
        catch {
            Start-Sleep -Milliseconds 100
        }
    }
    if ($actual -eq "__EZVIZ_READBACK_MISSING__" -or $actual -ne $Expected) {
        throw "Time field verification failed: expected=$Expected actual=$actual"
    }
}

function Dismiss-Continue([object]$MainWindow) {
    $script:continuePopup = $null
    [void][EzWinLite]::ShowWindow($MainWindow.Handle, 9)
    Start-Sleep -Milliseconds 180
    $popup = $null
    [EzWinLite]::EnumWindows({
        param($Handle, $Unused)
        $windowPid = [uint32]0
        [void][EzWinLite]::GetWindowThreadProcessId($Handle, [ref]$windowPid)
        if ($windowPid -ne $script:TargetPid -or -not [EzWinLite]::IsWindowVisible($Handle)) {
            return $true
        }
        if ([EzWinLite]::GetWindowTextLength($Handle) -gt 0) {
            return $true
        }
        $rect = [EzWinLite+RECT]::new()
        [void][EzWinLite]::GetWindowRect($Handle, [ref]$rect)
        $width = $rect.Right - $rect.Left
        $height = $rect.Bottom - $rect.Top
        if ($width -ge 330 -and $width -le 410 -and $height -ge 140 -and $height -le 200) {
            $script:continuePopup = [pscustomobject]@{
                Left = $rect.Left
                Top = $rect.Top
                Width = $width
                Height = $height
            }
            return $false
        }
        return $true
    }, [IntPtr]::Zero) | Out-Null
    if (-not $script:continuePopup) {
        return $false
    }
    $popup = $script:continuePopup
    Click-At ($popup.Left + 99) ($popup.Top + 89)
    Start-Sleep -Milliseconds 250
    Focus-Window $MainWindow.Handle
    Click-At ($MainWindow.Left + 720) ($MainWindow.Top + 400)
    Start-Sleep -Milliseconds 120
    [EzWinLite]::keybd_event(0x20, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 50
    [EzWinLite]::keybd_event(0x20, 0, 2, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 180
    $script:continuePopup = $null
    [EzWinLite]::EnumWindows({
        param($Handle, $Unused)
        $windowPid = [uint32]0
        [void][EzWinLite]::GetWindowThreadProcessId($Handle, [ref]$windowPid)
        if ($windowPid -ne $script:TargetPid -or -not [EzWinLite]::IsWindowVisible($Handle)) {
            return $true
        }
        if ([EzWinLite]::GetWindowTextLength($Handle) -gt 0) {
            return $true
        }
        $rect = [EzWinLite+RECT]::new()
        [void][EzWinLite]::GetWindowRect($Handle, [ref]$rect)
        $width = $rect.Right - $rect.Left
        $height = $rect.Bottom - $rect.Top
        if ($width -ge 300 -and $width -le 450 -and $height -ge 120 -and $height -le 220) {
            $script:continuePopup = $Handle
            return $false
        }
        return $true
    }, [IntPtr]::Zero) | Out-Null
    if ($script:continuePopup) {
        throw "Continue-playback popup did not close."
    }
    return $true
}

function Submit-Task {
    if ($StartTime -notmatch '^\d{2}:\d{2}:\d{2}$' -or $EndTime -notmatch '^\d{2}:\d{2}:\d{2}$') {
        throw "Submit requires HH:mm:ss start and end times."
    }
    $main = Get-TargetWindow
    Focus-Window $main.Handle
    if ($Day) {
        $actualDay = Read-PlaybackDate $main
        if ($actualDay -ne $Day) {
            throw "date-mismatch: playback date is '$actualDay', expected '$Day'"
        }
    }
    [void](Dismiss-Continue $main)
    $existing = Get-DownloadDialog
    if ($existing) {
        Close-DownloadDialog
        Start-Sleep -Milliseconds 250
    }
    $dialog = Open-DownloadDialog $main
    try {
        Focus-Window $dialog.Handle
        Start-Sleep -Milliseconds 180
        Fill-TimeField ($dialog.Left + 128) ($dialog.Top + 92) $StartTime
        Fill-TimeField ($dialog.Left + 334) ($dialog.Top + 92) $EndTime
        Focus-Window $dialog.Handle
        Click-At ($dialog.Left + 255) ($dialog.Top + 287)
        Start-Sleep -Milliseconds 450
        if (Get-DownloadDialog) {
            throw "Download dialog remained open after submit."
        }
        [void][EzWinLite]::ShowWindow($main.Handle, 6)
        Write-Result "ok|submitted|$StartTime|$EndTime"
    }
    catch {
        Close-DownloadDialog
        throw
    }
}

function Get-CalendarWindow {
    $script:calendarWindow = $null
    $script:calendarArea = 0
    [EzWinLite]::EnumWindows({
        param($Handle, $Unused)
        $windowPid = [uint32]0
        [void][EzWinLite]::GetWindowThreadProcessId($Handle, [ref]$windowPid)
        if ($windowPid -ne $script:TargetPid -or -not [EzWinLite]::IsWindowVisible($Handle)) {
            return $true
        }
        $length = [EzWinLite]::GetWindowTextLength($Handle)
        if ($length -eq 0) {
            return $true
        }
        $title = [Text.StringBuilder]::new($length + 1)
        [void][EzWinLite]::GetWindowText($Handle, $title, $title.Capacity)
        if ($title.ToString() -ne "PlayBackCalendar") {
            return $true
        }
        $rect = [EzWinLite+RECT]::new()
        [void][EzWinLite]::GetWindowRect($Handle, [ref]$rect)
        $width = $rect.Right - $rect.Left
        $height = $rect.Bottom - $rect.Top
        if ($width -lt 250 -or $height -lt 280) {
            return $true
        }
        $area = $width * $height
        if ($area -gt $script:calendarArea) {
            $script:calendarArea = $area
            $script:calendarWindow = [pscustomobject]@{
                Handle = $Handle
                Left = $rect.Left
                Top = $rect.Top
                Width = $width
                Height = $height
            }
        }
        return $true
    }, [IntPtr]::Zero) | Out-Null
    return $script:calendarWindow
}

function Initialize-Ocr {
    if ($script:OcrEngine) {
        return
    }
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
    [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
    [Windows.Storage.StorageFile, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
    [Windows.Globalization.Language, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
    $script:AsTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq "AsTask" -and $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq "IAsyncOperation``1"
    })[0]
    if (-not $script:AsTaskGeneric) {
        throw "WinRT async helper unavailable."
    }
    $script:OcrEngine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    if (-not $script:OcrEngine) {
        $script:OcrEngine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage(
            (New-Object Windows.Globalization.Language "en-US"))
    }
    if (-not $script:OcrEngine) {
        throw "Windows OCR engine unavailable."
    }
}

function Await-WinRt($Operation, $ResultType) {
    $task = $script:AsTaskGeneric.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    $task.Wait()
    return $task.Result
}

function Save-ScreenRegion([int]$X, [int]$Y, [int]$W, [int]$H, [string]$Path) {
    $source = New-Object System.Drawing.Bitmap($W, $H)
    $graphics = [System.Drawing.Graphics]::FromImage($source)
    try {
        $graphics.CopyFromScreen($X, $Y, 0, 0, $source.Size)
    }
    finally {
        $graphics.Dispose()
    }
    $scaled = New-Object System.Drawing.Bitmap(($W * 4), ($H * 4))
    $graphics2 = [System.Drawing.Graphics]::FromImage($scaled)
    try {
        $graphics2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics2.DrawImage($source, 0, 0, ($W * 4), ($H * 4))
    }
    finally {
        $graphics2.Dispose()
        $source.Dispose()
    }
    try {
        $scaled.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $scaled.Dispose()
    }
}

function Read-ImageText([string]$Path) {
    Initialize-Ocr
    $file = Await-WinRt ([Windows.Storage.StorageFile]::GetFileFromPathAsync($Path)) ([Windows.Storage.StorageFile])
    $stream = Await-WinRt ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    try {
        $decoder = Await-WinRt ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
        $bitmap = Await-WinRt ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
        $result = Await-WinRt ($script:OcrEngine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
        return (($result.Lines | ForEach-Object { $_.Text }) -join " ")
    }
    finally {
        $stream.Dispose()
    }
}

function Read-PlaybackDate([object]$MainWindow) {
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        $foreground = [EzWinLite]::GetForegroundWindow()
        if ($foreground -ne $MainWindow.Handle) {
            Focus-Window $MainWindow.Handle
            Start-Sleep -Milliseconds 200
            if ([EzWinLite]::GetForegroundWindow() -ne $MainWindow.Handle) {
                Click-At ($MainWindow.Left + [int]($MainWindow.Width / 2)) ($MainWindow.Top + 12)
                Start-Sleep -Milliseconds 280
            }
        }
        $path = Join-Path $env:TEMP ("ezviz-pill-" + [guid]::NewGuid().ToString("N") + ".png")
        try {
            Save-ScreenRegion ($MainWindow.Left + 640) ($MainWindow.Top + 714) 175 40 $path
            $text = Read-ImageText $path
        }
        finally {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
        $digits = ($text -replace '\D', '')
        if ($digits.Length -ge 8) {
            return $digits.Substring(0, 8)
        }
        Start-Sleep -Milliseconds 250
    }
    return ""
}

function Open-DateCalendar([object]$MainWindow, [datetime]$Target) {
    $cal = Get-CalendarWindow
    if ($cal) {
        Click-At ($MainWindow.Left + 330) ($MainWindow.Top + 210)
        Start-Sleep -Milliseconds 250
    }
    Focus-Window $MainWindow.Handle
    Click-At ($MainWindow.Left + $MainWindow.Width - 170) ($MainWindow.Top + $MainWindow.Height - 26)
    $cal = $null
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 150
        $cal = Get-CalendarWindow
        if ($cal) {
            break
        }
    }
    if (-not $cal) {
        throw "Date calendar did not open."
    }
    $headerPath = Join-Path $env:TEMP ("ezviz-calhdr-" + [guid]::NewGuid().ToString("N") + ".png")
    try {
        for ($iter = 0; $iter -lt 40; $iter++) {
            Save-ScreenRegion ($cal.Left + 90) ($cal.Top + 42) 120 30 $headerPath
            $text = Read-ImageText $headerPath
            $digits = ($text -replace '\D', '')
            if ($digits.Length -lt 6) {
                throw "Cannot read calendar header: '$text'"
            }
            $shownYear = [int]$digits.Substring(0, 4)
            $shownMonth = [int]$digits.Substring(4, 2)
            if ($shownYear -eq $Target.Year -and $shownMonth -eq $Target.Month) {
                break
            }
            $delta = ($Target.Year * 12 + $Target.Month) - ($shownYear * 12 + $shownMonth)
            if ($delta -eq 0) {
                break
            }
            $arrowX = 0
            if ($delta -lt 0) {
                $arrowX = $cal.Left + [int](18 * ($cal.Width / 300.0))
            }
            else {
                $arrowX = $cal.Left + [int](283 * ($cal.Width / 300.0))
            }
            Click-At $arrowX ($cal.Top + [int](56 * ($cal.Height / 360.0)))
            Start-Sleep -Milliseconds 380
            $cal = Get-CalendarWindow
            if (-not $cal) {
                throw "Calendar closed while changing month."
            }
        }
    }
    finally {
        Remove-Item -LiteralPath $headerPath -Force -ErrorAction SilentlyContinue
    }
    return $cal
}

function Select-Date([string]$TargetDay) {
    if ($TargetDay -notmatch '^\d{8}$') {
        throw "selectdate requires -Day yyyyMMdd."
    }
    $target = [datetime]::ParseExact($TargetDay, "yyyyMMdd", $null)
    $main = Get-TargetWindow
    Focus-Window $main.Handle
    [void](Dismiss-Continue $main)
    if (Get-DownloadDialog) {
        Close-DownloadDialog
        Start-Sleep -Milliseconds 200
    }
    $first = Get-Date -Year $target.Year -Month $target.Month -Day 1 -Hour 0 -Minute 0 -Second 0
    $last = $first.AddMonths(1).AddDays(-1)
    $lastSunday = $last.AddDays(-[int]$last.DayOfWeek)
    $gridStart = $lastSunday.AddDays(-35)
    $index = [int](($target - $gridStart).TotalDays)
    if ($index -lt 0 -or $index -ge 42) {
        throw "Target date outside the 6-row calendar grid."
    }
    $column = $index % 7
    $row = [int][math]::Floor($index / 7)
    $rowAttempts = @($row)
    if ($row + 1 -le 5) {
        $rowAttempts += ($row + 1)
    }
    if ($row - 1 -ge 0) {
        $rowAttempts += ($row - 1)
    }
    $actual = ""
    foreach ($rowIndex in $rowAttempts) {
        $cal = Open-DateCalendar $main $target
        $sx = $cal.Width / 300.0
        $sy = $cal.Height / 360.0
        $cellX = [int]($cal.Left + (27 + 40 * $column) * $sx)
        $cellY = [int]($cal.Top + (131 + 39 * $rowIndex) * $sy)
        Click-At $cellX $cellY
        Start-Sleep -Milliseconds 650
        if (Get-CalendarWindow) {
            Click-At ($main.Left + 330) ($main.Top + 210)
            Start-Sleep -Milliseconds 200
        }
        $actual = Read-PlaybackDate $main
        if ($actual -eq $TargetDay) {
            return "date-ok|$TargetDay|row=$rowIndex"
        }
    }
    throw "Date verification failed: expected=$TargetDay actual=$actual"
}

try {
    switch ($Action) {
        "submit" {
            Submit-Task
        }
        "filltest" {
            if ($StartTime -notmatch '^\d{2}:\d{2}:\d{2}$' -or $EndTime -notmatch '^\d{2}:\d{2}:\d{2}$') {
                throw "Fill test requires HH:mm:ss start and end times."
            }
            $main = Get-TargetWindow
            Focus-Window $main.Handle
            [void](Dismiss-Continue $main)
            $dialog = Open-DownloadDialog $main
            Focus-Window $dialog.Handle
            Fill-TimeField ($dialog.Left + 128) ($dialog.Top + 92) $StartTime
            Fill-TimeField ($dialog.Left + 334) ($dialog.Top + 92) $EndTime
            Close-DownloadDialog
            [void][EzWinLite]::ShowWindow($main.Handle, 6)
            Write-Result "ok|filltest|$StartTime|$EndTime"
        }
        "inspect" {
            Add-Type -AssemblyName UIAutomationClient
            Add-Type -AssemblyName UIAutomationTypes
            $main = Get-TargetWindow
            $root = [System.Windows.Automation.AutomationElement]::FromHandle($script:mainWindow)
            $all = $root.FindAll(
                [System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.Condition]::TrueCondition
            )
            $rows = [System.Collections.Generic.List[string]]::new()
            foreach ($element in $all) {
                try {
                    $name = $element.Current.Name
                    $type = $element.Current.ControlType.ProgrammaticName
                    $autoId = $element.Current.AutomationId
                    $rect = $element.Current.BoundingRectangle
                    if ($name -or $autoId -or $type -match 'Edit|Button|Calendar|Text') {
                        $rows.Add(("name={0}`ttype={1}`tid={2}`tclass={3}`trect={4},{5},{6},{7}" -f
                            $name, $type, $autoId, $element.Current.ClassName,
                            [int]$rect.Left, [int]$rect.Top, [int]$rect.Width, [int]$rect.Height))
                    }
                }
                catch {
                }
            }
            [void][EzWinLite]::ShowWindow($main.Handle, 6)
            Write-Result ("ok|inspect|" + ($rows -join "`n"))
        }
        "dismiss" {
            $main = Get-TargetWindow
            $dismissed = Dismiss-Continue $main
            [void][EzWinLite]::ShowWindow($main.Handle, 6)
            Write-Result "ok|dismissed|$dismissed"
        }
        "selectdate" {
            $result = Select-Date $Day
            if ($script:mainWindow) {
                [void][EzWinLite]::ShowWindow($script:mainWindow, 6)
            }
            Write-Result "ok|selectdate|$result"
        }
        "verifydate" {
            $main = Get-TargetWindow
            Focus-Window $main.Handle
            $actual = Read-PlaybackDate $main
            [void][EzWinLite]::ShowWindow($main.Handle, 6)
            Write-Result "ok|verifydate|$actual"
        }
        "minimize" {
            $main = Get-TargetWindow
            [void][EzWinLite]::ShowWindow($main.Handle, 6)
            Write-Result "ok|minimized"
        }
        "probe" {
            $main = Get-TargetWindow
            $dialog = Get-DownloadDialog
            $dialogText = ""
            if ($dialog) {
                $dialogText = "$($dialog.Left),$($dialog.Top),$($dialog.Width),$($dialog.Height)"
            }
            [void][EzWinLite]::ShowWindow($main.Handle, 6)
            Write-Result "ok|probe|pid=$($script:TargetPid)|$($main.Left),$($main.Top),$($main.Width),$($main.Height)|$dialogText"
        }
    }
}
catch {
    Write-Result "error|$($_.Exception.Message)"
    exit 1
}
