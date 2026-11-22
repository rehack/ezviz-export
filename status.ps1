param(
    [Parameter(Mandatory=$true)][string]$Day,
    [Parameter(Mandatory=$true)][string]$FromTime,
    [Parameter(Mandatory=$true)][string]$ToTime,
    [string]$Tag,
    [string]$Serial = "K68413322",
    [int]$Channel = 1,
    [string]$PlugLog = "D:\Program Files (x86)\Ezviz Studio\log\PLUG.log"
)

$ErrorActionPreference = "Stop"
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
        throw "Invalid time: $Value"
    }
    return $digits
}

$dayDate = [datetime]::ParseExact($Day, "yyyyMMdd", $null)
$fromDigits = Normalize-Time $FromTime
$toDigits = Normalize-Time $ToTime
if (-not $Tag) {
    $Tag = "day${Day}_$fromDigits-$toDigits"
}
if ($Tag -notmatch '^[A-Za-z0-9._-]+$') {
    throw "Tag may contain only letters, digits, dot, underscore and hyphen."
}
$start = $dayDate.Add([timespan]::ParseExact($fromDigits, "hhmmss", $null))
$end = $dayDate.Add([timespan]::ParseExact($toDigits, "hhmmss", $null))
$StateRoot = Join-Path $ToolRoot "state\$Tag"
$DoneFile = Join-Path $StateRoot "done.txt"
$InvalidFile = Join-Path $StateRoot "invalid.txt"
$FatalFile = Join-Path $StateRoot "fatal.txt"
$LogFile = Join-Path $StateRoot "export.log"

$expectedKeys = [System.Collections.Generic.List[string]]::new()
$expectedKeySet = [System.Collections.Generic.HashSet[string]]::new()
$cursor = $start
while ($cursor -lt $end) {
    $segmentEnd = $cursor.AddMinutes(5)
    if ($segmentEnd -gt $end) {
        $segmentEnd = $end
    }
    $key = "${Serial}_${Channel}_$($cursor.ToString('yyyyMMddHHmmss'))_$($segmentEnd.ToString('yyyyMMddHHmmss'))"
    $expectedKeys.Add($key)
    [void]$expectedKeySet.Add($key)
    $cursor = $segmentEnd
}

$completed = @{}
if (Test-Path -LiteralPath $DoneFile) {
    foreach ($line in (Get-Content -LiteralPath $DoneFile -ErrorAction SilentlyContinue)) {
        $key = $line.Trim()
        if ($key) {
            $completed[$key] = $true
        }
    }
}

$invalid = @{}
if (Test-Path -LiteralPath $InvalidFile) {
    foreach ($line in (Get-Content -LiteralPath $InvalidFile -ErrorAction SilentlyContinue)) {
        $key = ($line -split "`t", 2)[0].Trim()
        if ($expectedKeySet.Contains($key)) {
            $invalid[$key] = $true
        }
    }
}

$fatalReason = ""
if (Test-Path -LiteralPath $FatalFile) {
    $fatalReason = (Get-Content -LiteralPath $FatalFile -Encoding UTF8 -ErrorAction SilentlyContinue | Select-Object -First 1)
}

$statusMap = @{}
$statusReadOk = $false
for ($attempt = 0; $attempt -lt 5; $attempt++) {
    try {
        $stream = [IO.File]::Open($PlugLog, "Open", "Read", "ReadWrite")
        $reader = New-Object IO.StreamReader($stream)
        try {
            while (-not $reader.EndOfStream) {
                $line = $reader.ReadLine()
                if ($line -match 'strDownloadKey:(K\d+_\d+_\d{14}_\d{14}) iDownloadStatus:(\d)') {
                    $key = $matches[1]
                    if ($expectedKeySet.Contains($key)) {
                        $statusMap[$key] = [int]$matches[2]
                    }
                }
            }
        }
        finally {
            $reader.Close()
            $stream.Close()
        }
        $statusReadOk = $true
        break
    }
    catch {
        Start-Sleep -Milliseconds 250
    }
}
if (-not $statusReadOk) {
    Write-Warning "Unable to read PLUG.log after 5 attempts. Queue status may be incomplete."
}

$missing = @($expectedKeys | Where-Object { -not $completed.ContainsKey($_) -and -not $invalid.ContainsKey($_) })
[pscustomobject]@{
    Tag = $Tag
    Date = $Day
    Range = "$($start.ToString('HH:mm:ss'))-$($end.ToString('HH:mm:ss'))"
    Expected = $expectedKeys.Count
    Validated = $completed.Count
    Invalid = $invalid.Count
    Remaining = $missing.Count
    Inflight = @($expectedKeys | Where-Object { $statusMap[$_] -in 0, 1 }).Count
    Failed = @($expectedKeys | Where-Object { $statusMap[$_] -in 3, 5 }).Count
    Fatal = $fatalReason
    State = $StateRoot
} | Format-List

if ($fatalReason) {
    Write-Warning "导出已停止：$fatalReason"
}

$queueRows = foreach ($key in $expectedKeys) {
    $status = "not-submitted"
    if ($completed.ContainsKey($key)) {
        $status = "validated"
    }
    elseif ($invalid.ContainsKey($key)) {
        $status = "invalid-file"
    }
    elseif ($statusMap.ContainsKey($key)) {
        $status = switch ($statusMap[$key]) {
            0 { "queued" }
            1 { "downloading" }
            3 { "failed" }
            4 { "downloaded-not-validated" }
            5 { "failed/cancelled" }
            default { "status-$($statusMap[$key])" }
        }
    }
    [pscustomobject]@{
        Segment = $key.Split("_")[2] + "-" + $key.Split("_")[3].Substring(8)
        Status = $status
    }
}
$queueRows | Format-Table -AutoSize

if (Test-Path -LiteralPath $LogFile) {
    "--- recent log ---"
    Get-Content -LiteralPath $LogFile -Tail 12 -Encoding UTF8
}
