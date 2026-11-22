param(
    [Parameter(Mandatory=$true)][string]$Day,
    [Parameter(Mandatory=$true)][string]$FromTime,
    [Parameter(Mandatory=$true)][string]$ToTime,
    [string]$Tag,
    [string]$Serial = "K68413322",
    [int]$Channel = 1,
    [int]$MaxInflight = 4,
    [int]$MaxAttempts = 3,
    [int]$Hours = 24,
    [string]$RecordRoot = "E:\ezviz-record",
    [string]$PlugLog = "D:\Program Files (x86)\Ezviz Studio\log\PLUG.log",
    [string]$FFprobe = "D:\ffmpeg\bin\ffprobe.exe"
)

$ErrorActionPreference = "Stop"
$ToolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Runner = Join-Path $ToolRoot "run-ui-task.ps1"

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

function Append-SharedLine([string]$Path, [string]$Value) {
    $encoding = New-Object Text.UTF8Encoding($false)
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        $stream = $null
        $writer = $null
        try {
            $stream = New-Object IO.FileStream(
                $Path,
                [IO.FileMode]::Append,
                [IO.FileAccess]::Write,
                [IO.FileShare]::ReadWrite
            )
            $writer = New-Object IO.StreamWriter($stream, $encoding)
            $writer.WriteLine($Value)
            $writer.Flush()
            $writer.Dispose()
            return
        }
        catch {
            if ($writer) {
                try { $writer.Dispose() } catch { }
            }
            elseif ($stream) {
                try { $stream.Dispose() } catch { }
            }
            if ($attempt -eq 19) {
                throw
            }
            Start-Sleep -Milliseconds 100
        }
    }
}

function Write-Log([string]$Message) {
    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Append-SharedLine $LogFile $line
    Write-Output $line
}

$dayDate = [datetime]::ParseExact($Day, "yyyyMMdd", $null)
$fromDigits = Normalize-Time $FromTime
$toDigits = Normalize-Time $ToTime
$fromDateTime = $dayDate.Add([timespan]::ParseExact($fromDigits, "hhmmss", $null))
$toDateTime = $dayDate.Add([timespan]::ParseExact($toDigits, "hhmmss", $null))
if ($toDateTime -le $fromDateTime) {
    throw "End time must be later than start time."
}
if (-not $Tag) {
    $Tag = "day${Day}_$fromDigits-$toDigits"
}
if ($Tag -notmatch '^[A-Za-z0-9._-]+$') {
    throw "Tag may contain only letters, digits, dot, underscore and hyphen."
}
if ($MaxInflight -lt 1 -or $MaxInflight -gt 20) {
    throw "MaxInflight must be between 1 and 20."
}
if (-not (Test-Path -LiteralPath $PlugLog)) {
    throw "PLUG.log not found: $PlugLog"
}
if (-not (Test-Path -LiteralPath $RecordRoot)) {
    throw "Record directory not found: $RecordRoot"
}
if (-not (Test-Path -LiteralPath $FFprobe)) {
    throw "ffprobe not found: $FFprobe"
}

$StateRoot = Join-Path $ToolRoot "state\$Tag"
$LogFile = Join-Path $StateRoot "export.log"
$DoneFile = Join-Path $StateRoot "done.txt"
$InvalidFile = Join-Path $StateRoot "invalid.txt"
$FatalFile = Join-Path $StateRoot "fatal.txt"
$PidFile = Join-Path $StateRoot "controller.pid"
$HeartbeatFile = Join-Path $StateRoot "controller.heartbeat"
$StopFile = Join-Path $StateRoot "stop"
New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null
Remove-Item -LiteralPath $InvalidFile -Force -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath $FatalFile) {
    Write-Log "fatal state exists; refusing to start"
    exit 3
}

if (Test-Path -LiteralPath $PidFile) {
    $existingPid = 0
    [void][int]::TryParse(
        (Get-Content -LiteralPath $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1),
        [ref]$existingPid
    )
    $existingProcess = $null
    if ($existingPid -gt 0 -and $existingPid -ne $PID) {
        $existingProcess = Get-Process -Id $existingPid -ErrorAction SilentlyContinue
    }
    if ($existingProcess -and $existingProcess.ProcessName -in "powershell", "pwsh") {
        $heartbeatFresh = $false
        if (Test-Path -LiteralPath $HeartbeatFile) {
            $heartbeatAge = ((Get-Date) - (Get-Item -LiteralPath $HeartbeatFile).LastWriteTime).TotalMinutes
            $heartbeatFresh = $heartbeatAge -lt 3
        }
        if ($heartbeatFresh) {
            Write-Log "already running pid=$existingPid"
            exit 0
        }
        Write-Log "stale controller pid=$existingPid; starting replacement"
    }
}
Set-Content -LiteralPath $PidFile -Value $PID -Encoding UTF8
Set-Content -LiteralPath $HeartbeatFile -Value (Get-Date -Format "o") -Encoding UTF8

$windows = [System.Collections.Generic.List[object]]::new()
$cursor = $fromDateTime
while ($cursor -lt $toDateTime) {
    $end = $cursor.AddMinutes(5)
    if ($end -gt $toDateTime) {
        $end = $toDateTime
    }
    $windows.Add([pscustomobject]@{
        Start = $cursor
        End = $end
        Key = "${Serial}_${Channel}_$($cursor.ToString('yyyyMMddHHmmss'))_$($end.ToString('yyyyMMddHHmmss'))"
        ExpectedSeconds = [int](($end - $cursor).TotalSeconds)
    })
    $cursor = $end
}

$windowKeys = @{}
foreach ($item in $windows) {
    $windowKeys[$item.Key] = $item
}
Write-Log "plan segments=$($windows.Count) day=$Day $($fromDateTime.ToString('HH:mm:ss'))-$($toDateTime.ToString('HH:mm:ss')) inflight=$MaxInflight"

$statusMap = @{}
$script:LogOffset = [long]0
$script:LogRemainder = ""
$script:LogReadFailures = 0
$script:NewKeys = [System.Collections.Generic.List[string]]::new()

function Update-StatusMap {
    $script:NewKeys = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-Path -LiteralPath $PlugLog)) {
        return
    }
    $stream = $null
    try {
        $stream = [IO.File]::Open($PlugLog, "Open", "Read", "ReadWrite")
        if ($stream.Length -lt $script:LogOffset) {
            $script:LogOffset = [long]0
            $script:LogRemainder = ""
        }
        $stream.Position = $script:LogOffset
        $available = [int]($stream.Length - $script:LogOffset)
        if ($available -le 0) {
            return
        }
        $buffer = New-Object byte[] $available
        $read = $stream.Read($buffer, 0, $available)
        $script:LogOffset += $read
        $text = $script:LogRemainder + [Text.Encoding]::UTF8.GetString($buffer, 0, $read)
        $script:LogReadFailures = 0
    }
    catch {
        $script:LogReadFailures++
        return
    }
    finally {
        if ($stream) {
            $stream.Close()
        }
    }

    $lines = $text -split "`r?`n"
    if ($text.EndsWith("`n")) {
        $script:LogRemainder = ""
    }
    else {
        $script:LogRemainder = $lines[-1]
        if ($lines.Count -le 1) {
            return
        }
        $lines = $lines[0..($lines.Count - 2)]
    }
    foreach ($line in $lines) {
        if ($line -match '(K\d+_\d+_\d{14}_\d{14})') {
            $observedKey = $matches[1]
            if (-not $script:NewKeys.Contains($observedKey)) {
                $script:NewKeys.Add($observedKey)
            }
        }
        if ($line -match 'strDownloadKey:(K\d+_\d+_\d{14}_\d{14}) iDownloadStatus:(\d)') {
            $key = $matches[1]
            if ($windowKeys.ContainsKey($key)) {
                $statusMap[$key] = [int]$matches[2]
            }
        }
    }
}

function Get-RecordingResult([string]$Key, [int]$ExpectedSeconds) {
    $directory = Join-Path $RecordRoot $Key
    if (-not (Test-Path -LiteralPath $directory)) {
        return [pscustomobject]@{ Valid = $false; Duration = 0.0; Reason = "directory missing" }
    }
    $files = @(
        Get-ChildItem -LiteralPath $directory -Filter "*.mp4" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch '-bak' -and $_.Length -ge 100000 } |
            Sort-Object Name
    )
    if ($files.Count -eq 0) {
        return [pscustomobject]@{ Valid = $false; Duration = 0.0; Reason = "no valid mp4" }
    }
    $total = 0.0
    foreach ($file in $files) {
        $durationText = (& $FFprobe -v error -show_entries format=duration -of default=nw=1:nk=1 $file.FullName 2>$null).Trim()
        $duration = 0.0
        [void][double]::TryParse(
            $durationText,
            [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$duration
        )
        if ($LASTEXITCODE -ne 0 -or $duration -lt 1) {
            return [pscustomobject]@{ Valid = $false; Duration = $total; Reason = "bad file $($file.Name)" }
        }
        $total += $duration
    }
    if ($total -lt ($ExpectedSeconds - 8)) {
        return [pscustomobject]@{ Valid = $false; Duration = $total; Reason = "duration too short" }
    }
    if ($total -gt ($ExpectedSeconds + 8)) {
        return [pscustomobject]@{ Valid = $false; Duration = $total; Reason = "duration too long or duplicate files" }
    }
    return [pscustomobject]@{ Valid = $true; Duration = $total; Reason = "" }
}

function Get-SegmentResult([object]$Window) {
    return Get-RecordingResult $Window.Key $Window.ExpectedSeconds
}

function Submit-Segment([object]$Window, [int]$PreviousStatus) {
    try {
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Runner `
            -Action submit `
            -StartTime $Window.Start.ToString("HH:mm:ss") `
            -EndTime $Window.End.ToString("HH:mm:ss") `
            -Day $Day 2>&1
        if ($LASTEXITCODE -ne 0) {
            return "ui-error: $($output -join ' ')"
        }
        for ($wait = 0; $wait -lt 40; $wait++) {
            Start-Sleep -Milliseconds 250
            Update-StatusMap
            if ($statusMap.ContainsKey($Window.Key) -and $statusMap[$Window.Key] -ne $PreviousStatus) {
                return "ok"
            }
            foreach ($observedKey in $script:NewKeys) {
                $parts = $observedKey.Split("_")
                if ($parts.Count -ne 4) {
                    continue
                }
                $sameTimes = $parts[2].Substring(8) -eq $Window.Start.ToString("HHmmss") -and
                    $parts[3].Substring(8) -eq $Window.End.ToString("HHmmss")
                if ($sameTimes -and $observedKey -ne $Window.Key) {
                    return "date-or-device-mismatch:$observedKey"
                }
            }
        }
        return "log verification failed"
    }
    catch {
        return "submit error: $($_.Exception.Message)"
    }
}

$completed = @{}
$doneWritten = @{}
if (Test-Path -LiteralPath $DoneFile) {
    foreach ($line in (Get-Content -LiteralPath $DoneFile -ErrorAction SilentlyContinue)) {
        $key = $line.Trim()
        if ($windowKeys.ContainsKey($key) -and -not $doneWritten.ContainsKey($key)) {
            $doneWritten[$key] = $true
        }
        if ($windowKeys.ContainsKey($key) -and -not $completed.ContainsKey($key)) {
            $result = Get-SegmentResult $windowKeys[$key]
            if ($result.Valid) {
                $completed[$key] = $true
            }
        }
    }
}

$recordingCache = @{}
$recordingPattern = '^' + [regex]::Escape($Serial) + '_' + $Channel + '_(\d{14})_(\d{14})$'
$actualRecordings = [System.Collections.Generic.List[object]]::new()
foreach ($directory in (Get-ChildItem -LiteralPath $RecordRoot -Directory -ErrorAction SilentlyContinue)) {
    if ($directory.Name -notmatch $recordingPattern) {
        continue
    }
    $recordingStart = [datetime]::ParseExact($matches[1], "yyyyMMddHHmmss", $null)
    $recordingEnd = [datetime]::ParseExact($matches[2], "yyyyMMddHHmmss", $null)
    if ($recordingStart -lt $fromDateTime -or $recordingEnd -gt $toDateTime -or $recordingEnd -le $recordingStart) {
        continue
    }
    $expectedSeconds = [int](($recordingEnd - $recordingStart).TotalSeconds)
    if (-not $recordingCache.ContainsKey($directory.Name)) {
        $recordingCache[$directory.Name] = Get-RecordingResult $directory.Name $expectedSeconds
    }
    if ($recordingCache[$directory.Name].Valid) {
        $actualRecordings.Add([pscustomobject]@{
            Start = $recordingStart
            End = $recordingEnd
            Key = $directory.Name
        })
    }
}

$recovered = 0
foreach ($item in $windows) {
    if ($completed.ContainsKey($item.Key)) {
        continue
    }
    $coverageEnd = $item.Start
    $covered = $false
    while ($coverageEnd -lt $item.End) {
        $nextRecording = $actualRecordings |
            Where-Object { $_.Start -le $coverageEnd -and $_.End -gt $coverageEnd } |
            Sort-Object End -Descending |
            Select-Object -First 1
        if (-not $nextRecording) {
            break
        }
        $coverageEnd = $nextRecording.End
        if ($coverageEnd -ge $item.End) {
            $covered = $true
            break
        }
    }
    if ($covered) {
        $completed[$item.Key] = $true
        if (-not $doneWritten.ContainsKey($item.Key)) {
            Append-SharedLine $DoneFile $item.Key
            $doneWritten[$item.Key] = $true
        }
        $recovered++
    }
}
Write-Log "resume validated=$($completed.Count) recovered_from_existing=$recovered"

$attempts = @{}
$submitted = @{}
$invalid = @{}
$validationFailures = @{}
$fatal = $false
$fatalReason = ""
$deadline = (Get-Date).AddHours($Hours)
$lastProgressLog = [datetime]::MinValue

Write-Log "selecting playback date $Day"
try {
    $selectOutput = ((& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Runner `
        -Action selectdate -Day $Day 2>&1) | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw $selectOutput
    }
    Write-Log "date selected: $selectOutput"
}
catch {
    $fatal = $true
    $fatalReason = "无法把客户端切换到目标日期 $Day，已停止以免下载错误日期：$($_.Exception.Message)"
    Write-Log "FATAL $fatalReason"
}

try {
    while ((Get-Date) -lt $deadline) {
        if ($fatal) {
            break
        }
        Set-Content -LiteralPath $HeartbeatFile -Value (Get-Date -Format "o") -Encoding UTF8
        if (Test-Path -LiteralPath $StopFile) {
            Write-Log "stop requested"
            break
        }

        Update-StatusMap
        if ($script:LogReadFailures -ge 10) {
            Write-Log "log read retry failures=$($script:LogReadFailures)"
            $script:LogReadFailures = 0
        }

        foreach ($item in $windows) {
            if ($completed.ContainsKey($item.Key) -or $invalid.ContainsKey($item.Key)) {
                continue
            }
            if ($statusMap[$item.Key] -eq 4) {
                $result = Get-SegmentResult $item
                if ($result.Valid) {
                    $completed[$item.Key] = $true
                    if (-not $doneWritten.ContainsKey($item.Key)) {
                        Append-SharedLine $DoneFile $item.Key
                        $doneWritten[$item.Key] = $true
                    }
                    Write-Log "validated $($item.Key) duration=$([math]::Round($result.Duration,2))s"
                }
                else {
                    $validationFailures[$item.Key] = [int]$validationFailures[$item.Key] + 1
                    if ($validationFailures[$item.Key] -lt 5) {
                        Write-Log "validate retry $($validationFailures[$item.Key])/5 $($item.Key) reason=$($result.Reason)"
                    }
                    else {
                        $invalid[$item.Key] = $result.Reason
                        Append-SharedLine $InvalidFile "$($item.Key)`t$($result.Reason)"
                        Write-Log "INVALID $($item.Key) reason=$($result.Reason)"
                    }
                }
            }
        }

        if ($completed.Count -eq $windows.Count) {
            Write-Log "work complete validated=$($completed.Count)/$($windows.Count)"
            break
        }

        $now = Get-Date
        foreach ($key in @($submitted.Keys)) {
            if ($statusMap.ContainsKey($key)) {
                $submitted.Remove($key)
            }
            elseif (($now - $submitted[$key]).TotalSeconds -gt 75) {
                Write-Log "submit status timeout $key"
                $submitted.Remove($key)
                $attempts[$key] = [int]$attempts[$key] + 1
            }
        }

        $inflight = @($windows | Where-Object {
            $statusMap.ContainsKey($_.Key) -and $statusMap[$_.Key] -in 0, 1
        })
        $newCandidates = @($windows | Where-Object {
            -not $statusMap.ContainsKey($_.Key) -and
            -not $submitted.ContainsKey($_.Key) -and
            -not $completed.ContainsKey($_.Key) -and
            -not $invalid.ContainsKey($_.Key) -and
            [int]$attempts[$_.Key] -lt $MaxAttempts
        })
        $retryCandidates = @($windows | Where-Object {
            $statusMap[$_.Key] -in 3, 5 -and
            [int]$attempts[$_.Key] -lt $MaxAttempts -and
            -not $submitted.ContainsKey($_.Key) -and
            -not $completed.ContainsKey($_.Key) -and
            -not $invalid.ContainsKey($_.Key)
        })
        $candidates = @($newCandidates) + @($retryCandidates)

        $need = $MaxInflight - $inflight.Count
        if ($need -gt 0 -and $candidates.Count -gt 0) {
            foreach ($item in ($candidates | Select-Object -First $need)) {
                if ($submitted.ContainsKey($item.Key)) {
                    continue
                }
                $previousStatus = -1
                if ($statusMap.ContainsKey($item.Key)) {
                    $previousStatus = $statusMap[$item.Key]
                }
                $submitted[$item.Key] = Get-Date
                $attempts[$item.Key] = [int]$attempts[$item.Key] + 1
                Write-Log "submit $($item.Start.ToString('HH:mm:ss'))-$($item.End.ToString('HH:mm:ss')) key=$($item.Key)"
                $result = Submit-Segment $item $previousStatus
                if ($result -eq "ok") {
                    Write-Log "submitted $($item.Key)"
                }
                elseif ($result -like "date-or-device-mismatch:*") {
                    $actualKey = $result.Substring(24)
                    $fatal = $true
                    $fatalReason = "客户端当前日期或设备与目标不一致。目标日期=$Day，实际提交键=$actualKey"
                    Write-Log "FATAL $fatalReason"
                    break
                }
                elseif ($result -like "*date-mismatch*") {
                    $fatal = $true
                    $fatalReason = "提交前校验发现客户端回放日期不是目标日期 $Day，已阻止提交。详情：$result"
                    Write-Log "FATAL $fatalReason"
                    break
                }
                else {
                    $submitted.Remove($item.Key)
                    Write-Log "submit failed $($item.Key) attempt=$($attempts[$item.Key]) reason=$result"
                    Start-Sleep -Seconds 2
                }
            }
        }

        if ($fatal) {
            break
        }

        $allDoneOrInvalid = ($completed.Count + $invalid.Count -eq $windows.Count)
        $nothingPending = ($inflight.Count -eq 0 -and $submitted.Count -eq 0 -and $candidates.Count -eq 0)
        $canRetry = @($windows | Where-Object {
            $statusMap[$_.Key] -in 3, 5 -and
            [int]$attempts[$_.Key] -lt $MaxAttempts -and
            -not $completed.ContainsKey($_.Key)
        }).Count -gt 0
        if ($allDoneOrInvalid -or ($nothingPending -and -not $canRetry)) {
            if (-not $allDoneOrInvalid) {
                $fatal = $true
                $fatalReason = "有录像段连续提交失败，已达到最大重试次数 $MaxAttempts"
                Write-Log "FATAL $fatalReason"
            }
            break
        }

        if (((Get-Date) - $lastProgressLog).TotalMinutes -ge 5) {
            $progressInflight = @($windows | Where-Object {
                $statusMap.ContainsKey($_.Key) -and $statusMap[$_.Key] -in 0, 1
            }).Count
            Write-Log "progress validated=$($completed.Count) invalid=$($invalid.Count) inflight=$progressInflight submitted=$($submitted.Count) total=$($windows.Count)"
            $lastProgressLog = Get-Date
        }
        Start-Sleep -Seconds 3
    }
}
finally {
    $recordedPid = 0
    [void][int]::TryParse(
        (Get-Content -LiteralPath $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1),
        [ref]$recordedPid
    )
    if ($recordedPid -eq $PID) {
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $HeartbeatFile -Force -ErrorAction SilentlyContinue
    }
}

if ($fatal) {
    Append-SharedLine $FatalFile $fatalReason
}
Write-Log "final validated=$($completed.Count)/$($windows.Count) invalid=$($invalid.Count) elapsed_deadline=$((Get-Date) -ge $deadline)"
if ($completed.Count -ne $windows.Count) {
    exit 2
}
exit 0
