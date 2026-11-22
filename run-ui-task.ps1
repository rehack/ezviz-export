param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("submit", "dismiss", "minimize", "probe", "filltest", "inspect", "selectdate", "verifydate")]
    [string]$Action,
    [string]$StartTime = "",
    [string]$EndTime = "",
    [string]$Day = "",
    [int]$TimeoutSeconds = 90
)

$ErrorActionPreference = "Stop"
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class EzvizUiLauncher {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct STARTUPINFO {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_INFORMATION {
        public IntPtr hProcess;
        public IntPtr hThread;
        public int dwProcessId;
        public int dwThreadId;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern bool CreateProcess(
        string applicationName,
        string commandLine,
        IntPtr processAttributes,
        IntPtr threadAttributes,
        bool inheritHandles,
        uint creationFlags,
        IntPtr environment,
        string currentDirectory,
        ref STARTUPINFO startupInfo,
        out PROCESS_INFORMATION processInformation
    );
    [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll")] public static extern bool TerminateProcess(IntPtr handle, uint exitCode);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr handle);
}
'@

$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$helper = Join-Path $toolRoot "ui-helper.ps1"
$resultFile = Join-Path $toolRoot ("ui-result-" + [guid]::NewGuid().ToString("N") + ".txt")
$powerShell = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
$arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$helper`" " +
    "-Action $Action -StartTime `"$StartTime`" -EndTime `"$EndTime`" -Day `"$Day`" -ResultFile `"$resultFile`""
$commandLine = "`"$powerShell`" $arguments"

$startupInfo = [EzvizUiLauncher+STARTUPINFO]::new()
$startupInfo.cb = [Runtime.InteropServices.Marshal]::SizeOf($startupInfo)
$startupInfo.lpDesktop = "WinSta0\Default"
$processInfo = [EzvizUiLauncher+PROCESS_INFORMATION]::new()

try {
    if (-not [EzvizUiLauncher]::CreateProcess(
        $powerShell,
        $commandLine,
        [IntPtr]::Zero,
        [IntPtr]::Zero,
        $false,
        0x08000000,
        [IntPtr]::Zero,
        $toolRoot,
        [ref]$startupInfo,
        [ref]$processInfo
    )) {
        throw "Unable to start UI helper. Win32Error=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }

    $waitResult = [EzvizUiLauncher]::WaitForSingleObject(
        $processInfo.hProcess,
        [uint32]($TimeoutSeconds * 1000)
    )
    if ($waitResult -eq 0x102) {
        [void][EzvizUiLauncher]::TerminateProcess($processInfo.hProcess, 1)
        [void][EzvizUiLauncher]::WaitForSingleObject($processInfo.hProcess, 2000)
    }

    if (-not (Test-Path -LiteralPath $resultFile)) {
        throw "UI helper timed out or exited without a result."
    }
    $result = (Get-Content -LiteralPath $resultFile -Raw -Encoding UTF8).Trim()
    if ($result -like "error|*") {
        throw ($result.Substring(6))
    }
    Write-Output $result
}
finally {
    if ($processInfo.hThread -ne [IntPtr]::Zero) {
        [void][EzvizUiLauncher]::CloseHandle($processInfo.hThread)
    }
    if ($processInfo.hProcess -ne [IntPtr]::Zero) {
        [void][EzvizUiLauncher]::CloseHandle($processInfo.hProcess)
    }
    Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue
}
