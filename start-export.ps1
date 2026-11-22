param(
    [string]$Day,
    [string]$FromTime,
    [string]$ToTime,
    [string]$Serial = "K68413322",
    [int]$Channel = 1,
    [int]$MaxInflight = 4,
    [int]$MaxAttempts = 3,
    [string]$Tag,
    [int]$Hours = 24,
    [switch]$NoWatch,
    [switch]$ResetFatal
)

$ErrorActionPreference = "Stop"
trap {
    Write-Host "启动失败：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
$ToolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

function Normalize-Time([string]$Value) {
    $digits = ($Value -replace '\D', '')
    switch ($digits.Length) {
        1 { $digits = "0${digits}0000" }
        2 { $digits += "0000" }
        3 { $digits = "0${digits}00" }
        4 { $digits += "00" }
        5 { $digits = "0$digits" }
    }
    if ($digits -notmatch '^\d{6}$') {
        throw "时间格式无效：$Value"
    }
    return $digits
}

function Get-ControllerState([string]$CandidateTag) {
    $stateRoot = Join-Path $ToolRoot "state\$CandidateTag"
    $pidFile = Join-Path $stateRoot "controller.pid"
    if (-not (Test-Path -LiteralPath $pidFile)) {
        return "none"
    }
    $controllerPid = 0
    [void][int]::TryParse(
        (Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1),
        [ref]$controllerPid
    )
    $controllerProcess = $null
    if ($controllerPid -gt 0) {
        $controllerProcess = Get-Process -Id $controllerPid -ErrorAction SilentlyContinue
    }
    if (-not $controllerProcess -or $controllerProcess.ProcessName -notin "powershell", "pwsh") {
        return "none"
    }
    $heartbeat = Join-Path $stateRoot "controller.heartbeat"
    if (-not (Test-Path -LiteralPath $heartbeat)) {
        return "stale"
    }
    $age = ((Get-Date) - (Get-Item -LiteralPath $heartbeat).LastWriteTime).TotalMinutes
    if ($age -lt 3) {
        return "active"
    }
    return "stale"
}

if (-not $Day -or -not $FromTime -or -not $ToTime) {
    $Day = Read-Host "日期（yyyyMMdd，例如 20261120）"
    $FromTime = Read-Host "开始时间（例如 9:15、0915、09:15:00）"
    $ToTime = Read-Host "结束时间（例如 17:30、1730、17:30:00）"
}

$dayDate = [datetime]::ParseExact($Day, "yyyyMMdd", $null)
$fromDigits = Normalize-Time $FromTime
$toDigits = Normalize-Time $ToTime
$fromDateTime = $dayDate.Add([timespan]::ParseExact($fromDigits, "hhmmss", $null))
$toDateTime = $dayDate.Add([timespan]::ParseExact($toDigits, "hhmmss", $null))
if ($toDateTime -le $fromDateTime) {
    throw "结束时间必须晚于开始时间。"
}
if ($MaxInflight -lt 1 -or $MaxInflight -gt 20) {
    throw "同时下载数必须在 1 到 20 之间。"
}

if (-not $Tag) {
    $Tag = "day${Day}_$fromDigits-$toDigits"
}
if ($Tag -notmatch '^[A-Za-z0-9._-]+$') {
    throw "Tag 只能包含字母、数字、点、下划线和连字符。"
}

$stateRoot = Join-Path $ToolRoot "state\$Tag"
$fatalFile = Join-Path $stateRoot "fatal.txt"
if ((Test-Path -LiteralPath $fatalFile) -and -not $ResetFatal) {
    $fatalReason = (Get-Content -LiteralPath $fatalFile -Encoding UTF8 -ErrorAction SilentlyContinue | Select-Object -First 1)
    throw "上次导出已熔断：$fatalReason`n请先选中正确日期，再删除 fatal.txt 或加 -ResetFatal 重新启动。"
}
$stateContainer = Join-Path $ToolRoot "state"
if (Test-Path -LiteralPath $stateContainer) {
    foreach ($candidateState in (Get-ChildItem -LiteralPath $stateContainer -Directory -ErrorAction SilentlyContinue)) {
        if ($candidateState.Name -eq $Tag) {
            continue
        }
        $candidateStatus = Get-ControllerState $candidateState.Name
        if ($candidateStatus -eq "active") {
            throw "已有导出任务正在运行：Tag=$($candidateState.Name)"
        }
        if ($candidateStatus -eq "stale") {
            $candidatePid = 0
            [void][int]::TryParse(
                (Get-Content -LiteralPath (Join-Path $candidateState.FullName "controller.pid") -ErrorAction SilentlyContinue | Select-Object -First 1),
                [ref]$candidatePid
            )
            if ($candidatePid -gt 0) {
                try {
                    Stop-Process -Id $candidatePid -Force -ErrorAction Stop
                }
                catch {
                    throw "旧控制器无法停止：PID=$candidatePid Tag=$($candidateState.Name)"
                }
            }
            Remove-Item -LiteralPath (Join-Path $candidateState.FullName "controller.pid") -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath (Join-Path $candidateState.FullName "controller.heartbeat") -Force -ErrorAction SilentlyContinue
        }
    }
}

$existingState = Get-ControllerState $Tag
if ($existingState -eq "active") {
    Write-Output "导出任务已在运行：Tag=$Tag"
    exit 0
}

if ($existingState -eq "stale") {
    $stalePid = 0
    [void][int]::TryParse(
        (Get-Content -LiteralPath (Join-Path $stateRoot "controller.pid") -ErrorAction SilentlyContinue | Select-Object -First 1),
        [ref]$stalePid
    )
    if ($stalePid -gt 0) {
        try {
            Stop-Process -Id $stalePid -Force -ErrorAction Stop
        }
        catch {
            throw "旧控制器仍在运行且无法停止：PID=$stalePid，$($_.Exception.Message)"
        }
    }
    Remove-Item -LiteralPath (Join-Path $stateRoot "controller.pid") -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $stateRoot "controller.heartbeat") -Force -ErrorAction SilentlyContinue
}

$recordRoot = "E:\ezviz-record"
$plugLog = "D:\Program Files (x86)\Ezviz Studio\log\PLUG.log"
$ffprobe = "D:\ffmpeg\bin\ffprobe.exe"
foreach ($requiredPath in @($recordRoot, $plugLog, $ffprobe)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "缺少必要文件或目录：$requiredPath"
    }
}
Write-Output "目标：$Day $($fromDateTime.ToString('HH:mm:ss'))-$($toDateTime.ToString('HH:mm:ss'))"
Write-Output "脚本会自动把客户端回放日期切换到 $Day，并在提交前逐个校验。"
$probeRunner = Join-Path $ToolRoot "run-ui-task.ps1"
$probeOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $probeRunner -Action probe -TimeoutSeconds 20 2>&1
if ($LASTEXITCODE -ne 0 -or ($probeOutput -join "`n") -notmatch '^ok\|probe\|') {
    throw "萤石客户端窗口检查失败：$($probeOutput -join ' ')"
}

New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
Remove-Item -LiteralPath (Join-Path $stateRoot "stop") -Force -ErrorAction SilentlyContinue
if ($ResetFatal) {
    Remove-Item -LiteralPath $fatalFile -Force -ErrorAction SilentlyContinue
}

$exportScript = Join-Path $ToolRoot "export.ps1"
$watchScript = Join-Path $ToolRoot "watch.ps1"
$controllerOut = Join-Path $stateRoot "controller-out.log"
$controllerErr = Join-Path $stateRoot "controller-err.log"
$controller = Start-Process -FilePath powershell.exe -ArgumentList @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $exportScript,
    "-Day", $Day, "-FromTime", $fromDigits, "-ToTime", $toDigits,
    "-Tag", $Tag, "-Serial", $Serial, "-Channel", "$Channel",
    "-MaxInflight", "$MaxInflight", "-MaxAttempts", "$MaxAttempts",
    "-Hours", "$Hours"
) -WindowStyle Hidden -RedirectStandardOutput $controllerOut -RedirectStandardError $controllerErr -PassThru

$heartbeatFile = Join-Path $stateRoot "controller.heartbeat"
$started = $false
for ($wait = 0; $wait -lt 30; $wait++) {
    Start-Sleep -Milliseconds 500
    if (Test-Path -LiteralPath $heartbeatFile) {
        $started = $true
        break
    }
    if ($controller.HasExited) {
        break
    }
}
if (-not $started) {
    $errorText = ""
    if (Test-Path -LiteralPath $controllerErr) {
        $errorText = (Get-Content -LiteralPath $controllerErr -Raw -Encoding UTF8).Trim()
    }
    Write-Output "控制器启动失败。"
    if ($errorText) {
        Write-Output $errorText
    }
    exit 1
}

Write-Output "控制器已启动：PID=$($controller.Id) Tag=$Tag"
Write-Output "状态目录：$stateRoot"

if (-not $NoWatch) {
    Start-Sleep -Seconds 1
    $watchOut = Join-Path $stateRoot "watch-out.log"
    $watchErr = Join-Path $stateRoot "watch-err.log"
    $watcher = Start-Process -FilePath powershell.exe -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $watchScript,
        "-Day", $Day, "-FromTime", $fromDigits, "-ToTime", $toDigits,
        "-Tag", $Tag, "-Serial", $Serial, "-Channel", "$Channel",
        "-MaxInflight", "$MaxInflight", "-MaxAttempts", "$MaxAttempts",
        "-Hours", "$Hours"
    ) -WindowStyle Hidden -RedirectStandardOutput $watchOut -RedirectStandardError $watchErr -PassThru
    Write-Output "看门狗已启动：PID=$($watcher.Id)"
}

Write-Output "查看进度："
Write-Output "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$ToolRoot\status.ps1`" -Day $Day -FromTime $fromDigits -ToTime $toDigits -Tag $Tag"
