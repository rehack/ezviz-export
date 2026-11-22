param(
    [Parameter(Mandatory=$true)][string]$Day,
    [Parameter(Mandatory=$true)][string]$FromTime,
    [Parameter(Mandatory=$true)][string]$ToTime,
    [Parameter(Mandatory=$true)][string]$Tag,
    [string]$Serial = "K68413322",
    [int]$Channel = 1,
    [int]$MaxInflight = 4,
    [int]$MaxAttempts = 3,
    [int]$Hours = 24,
    [int]$IntervalSeconds = 60
)

$ErrorActionPreference = "Stop"
$ToolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$StateRoot = Join-Path $ToolRoot "state\$Tag"
$WatchLog = Join-Path $StateRoot "watch.log"
$PidFile = Join-Path $StateRoot "controller.pid"
$HeartbeatFile = Join-Path $StateRoot "controller.heartbeat"
$DoneFile = Join-Path $StateRoot "done.txt"
$InvalidFile = Join-Path $StateRoot "invalid.txt"
$FatalFile = Join-Path $StateRoot "fatal.txt"
$StopFile = Join-Path $StateRoot "stop"
$ExportScript = Join-Path $ToolRoot "export.ps1"
New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null

function Write-WatchLog([string]$Message) {
    Add-Content -LiteralPath $WatchLog -Value ("{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message) -Encoding UTF8
}

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
        throw "Invalid time: $Value"
    }
    return $digits
}

$dayDate = [datetime]::ParseExact($Day, "yyyyMMdd", $null)
$fromDigits = Normalize-Time $FromTime
$toDigits = Normalize-Time $ToTime
if ($Tag -notmatch '^[A-Za-z0-9._-]+$') {
    throw "Tag may contain only letters, digits, dot, underscore and hyphen."
}
if ($MaxInflight -lt 1 -or $MaxInflight -gt 20) {
    throw "MaxInflight must be between 1 and 20."
}
$start = $dayDate.Add([timespan]::ParseExact($fromDigits, "hhmmss", $null))
$end = $dayDate.Add([timespan]::ParseExact($toDigits, "hhmmss", $null))
$expectedKeys = [System.Collections.Generic.HashSet[string]]::new()
$cursor = $start
while ($cursor -lt $end) {
    $segmentEnd = $cursor.AddMinutes(5)
    if ($segmentEnd -gt $end) {
        $segmentEnd = $end
    }
    [void]$expectedKeys.Add("${Serial}_${Channel}_$($cursor.ToString('yyyyMMddHHmmss'))_$($segmentEnd.ToString('yyyyMMddHHmmss'))")
    $cursor = $segmentEnd
}
$expected = $expectedKeys.Count

while ($true) {
    if (Test-Path -LiteralPath $StopFile) {
        Write-WatchLog "stop requested"
        return
    }
    if (Test-Path -LiteralPath $FatalFile) {
        Write-WatchLog "fatal state detected; watchdog stopped"
        return
    }
    $done = 0
    if (Test-Path -LiteralPath $DoneFile) {
        $done = @(
            Get-Content -LiteralPath $DoneFile -ErrorAction SilentlyContinue |
                Where-Object { $expectedKeys.Contains($_.Trim()) } |
                Select-Object -Unique
        ).Count
    }
    $invalid = 0
    if (Test-Path -LiteralPath $InvalidFile) {
        $invalid = @(
            Get-Content -LiteralPath $InvalidFile -ErrorAction SilentlyContinue |
                ForEach-Object { ($_ -split "`t", 2)[0].Trim() } |
                Where-Object { $expectedKeys.Contains($_) } |
                Select-Object -Unique
        ).Count
    }
    if ($done -ge $expected) {
        Write-WatchLog "work complete validated=$done/$expected"
        return
    }
    if (($done + $invalid) -ge $expected) {
        Write-WatchLog "work stopped incomplete validated=$done invalid=$invalid expected=$expected"
        return
    }

    $controllerPid = 0
    $alive = $false
    $fresh = $false
    if (Test-Path -LiteralPath $PidFile) {
        [void][int]::TryParse(
            (Get-Content -LiteralPath $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1),
            [ref]$controllerPid
        )
        $controllerProcess = $null
        if ($controllerPid -gt 0) {
            $controllerProcess = Get-Process -Id $controllerPid -ErrorAction SilentlyContinue
        }
        if ($controllerProcess -and $controllerProcess.ProcessName -in "powershell", "pwsh") {
            $alive = $true
            if (Test-Path -LiteralPath $HeartbeatFile) {
                $age = ((Get-Date) - (Get-Item -LiteralPath $HeartbeatFile).LastWriteTime).TotalMinutes
                $fresh = $age -lt 3
            }
        }
    }

    if (-not $alive) {
        Write-WatchLog "controller not running; restarting done=$done/$expected"
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $HeartbeatFile -Force -ErrorAction SilentlyContinue
        Start-Process -FilePath powershell.exe -ArgumentList @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $ExportScript,
            "-Day", $Day, "-FromTime", $fromDigits, "-ToTime", $toDigits,
            "-Tag", $Tag, "-Serial", $Serial, "-Channel", "$Channel",
            "-MaxInflight", "$MaxInflight", "-MaxAttempts", "$MaxAttempts",
            "-Hours", "$Hours"
        ) -WindowStyle Hidden `
          -RedirectStandardOutput (Join-Path $StateRoot "controller-out.log") `
          -RedirectStandardError (Join-Path $StateRoot "controller-err.log") | Out-Null
    }
    elseif (-not $fresh) {
        Write-WatchLog "controller pid=$controllerPid is stale; attempting restart"
        try {
            Stop-Process -Id $controllerPid -Force -ErrorAction Stop
            Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $HeartbeatFile -Force -ErrorAction SilentlyContinue
        }
        catch {
            Write-WatchLog "cannot stop stale controller pid=$controllerPid; will retry"
        }
    }

    Start-Sleep -Seconds $IntervalSeconds
}
