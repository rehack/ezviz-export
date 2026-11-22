param(
    [Parameter(Mandatory=$true)][string]$Day,
    [Parameter(Mandatory=$true)][string]$FromTime,
    [Parameter(Mandatory=$true)][string]$ToTime,
    [string]$Tag,
    [string]$Serial = "K68413322",
    [int]$Channel = 1,
    [string]$RecordRoot = "E:\ezviz-record",
    [string]$FFmpeg = "D:\ffmpeg\bin\ffmpeg.exe",
    [string]$FFprobe = "D:\ffmpeg\bin\ffprobe.exe",
    [switch]$Hourly,
    [switch]$FullDecode
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
if ($end -le $start) {
    throw "End time must be later than start time."
}

$keyPattern = '^' + [regex]::Escape($Serial) + '_' + $Channel + '_(\d{14})_(\d{14})$'
$availableRanges = [System.Collections.Generic.List[object]]::new()
foreach ($directory in (Get-ChildItem -LiteralPath $RecordRoot -Directory -ErrorAction Stop)) {
    if ($directory.Name -notmatch $keyPattern) {
        continue
    }
    $segmentStart = [datetime]::ParseExact($matches[1], "yyyyMMddHHmmss", $null)
    $segmentEnd = [datetime]::ParseExact($matches[2], "yyyyMMddHHmmss", $null)
    if ($segmentEnd -le $segmentStart) {
        continue
    }
    $availableRanges.Add([pscustomobject]@{
        Start = $segmentStart
        End = $segmentEnd
        Key = $directory.Name
        Directory = $directory.FullName
    })
}

$segments = [System.Collections.Generic.List[object]]::new()
$cursor = $start
while ($cursor -lt $end) {
    $candidate = $availableRanges |
        Where-Object { $_.Start -eq $cursor } |
        Sort-Object End -Descending |
        Select-Object -First 1
    if (-not $candidate) {
        $nextAvailable = $availableRanges |
            Where-Object { $_.Start -ge $cursor -and $_.End -le $end } |
            Sort-Object Start |
            Select-Object -First 1
        $nextText = ""
        if ($nextAvailable) {
            $nextText = " Next available: $($nextAvailable.Key)"
        }
        throw "Missing continuous recording at $($cursor.ToString('yyyy-MM-dd HH:mm:ss')).$nextText"
    }
    if ($candidate.End -gt $end) {
        throw "Segment extends beyond requested end: $($candidate.Key)"
    }
    $key = $candidate.Key
    $directory = $candidate.Directory
    $files = @(
        Get-ChildItem -LiteralPath $directory -Filter "*.mp4" -File |
            Where-Object { $_.Name -notmatch '-bak' -and $_.Length -ge 100000 } |
            Sort-Object Name
    )
    if ($files.Count -eq 0) {
        throw "No valid mp4 files: $key"
    }
    $duration = 0.0
    foreach ($file in $files) {
        $durationText = (& $FFprobe -v error -show_entries format=duration -of default=nw=1:nk=1 $file.FullName 2>$null).Trim()
        $value = 0.0
        [void][double]::TryParse(
            $durationText,
            [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$value
        )
        if ($LASTEXITCODE -ne 0 -or $value -lt 1) {
            throw "Invalid mp4: $($file.FullName)"
        }
        $duration += $value
    }
    $expectedSeconds = [int](($candidate.End - $candidate.Start).TotalSeconds)
    if ($duration -lt ($expectedSeconds - 8)) {
        throw "Segment too short: $key actual=$([math]::Round($duration,2))s expected=${expectedSeconds}s"
    }
    if ($duration -gt ($expectedSeconds + 8)) {
        throw "Segment too long or contains duplicate files: $key actual=$([math]::Round($duration,2))s expected=${expectedSeconds}s"
    }
    $segments.Add([pscustomobject]@{
        Start = $candidate.Start
        End = $candidate.End
        Key = $key
        Files = $files
        Duration = $duration
    })
    $cursor = $candidate.End
}

if ($Hourly) {
    $groups = @(
        $segments |
            Group-Object { $_.Start.ToString("yyyyMMddHH") } |
            ForEach-Object {
                $items = @($_.Group | Sort-Object Start)
                [pscustomobject]@{
                    Start = $items[0].Start
                    End = $items[-1].End
                    Segments = $items
                    Name = "$($items[0].Start.ToString('yyyyMMdd'))_$($items[0].Start.ToString('HH'))00-$($items[-1].End.ToString('HHmm'))"
                }
            }
    )
}
else {
    $groups = @(
        [pscustomobject]@{
            Start = $start
            End = $end
            Segments = @($segments)
            Name = "$($start.ToString('yyyyMMdd'))_$($start.ToString('HHmm'))-$($end.ToString('HHmm'))"
        }
    )
}

$outputRoot = Join-Path $ToolRoot "output\$Tag"
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
$results = [System.Collections.Generic.List[object]]::new()

foreach ($group in $groups) {
    $listFile = Join-Path $outputRoot ("concat-" + [guid]::NewGuid().ToString("N") + ".txt")
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($segment in $group.Segments) {
        foreach ($file in $segment.Files) {
            $lines.Add("file '$($file.FullName.Replace('\','/'))'")
        }
    }
    [IO.File]::WriteAllLines($listFile, $lines, (New-Object Text.UTF8Encoding($false)))
    $outputFile = Join-Path $outputRoot ("$($group.Name).mp4")
    & $FFmpeg -hide_banner -loglevel error -y -f concat -safe 0 -i $listFile -c copy -movflags +faststart $outputFile
    Remove-Item -LiteralPath $listFile -Force -ErrorAction SilentlyContinue
    if ($LASTEXITCODE -ne 0) {
        throw "ffmpeg merge failed: $outputFile"
    }
    $durationText = (& $FFprobe -v error -show_entries format=duration -of default=nw=1:nk=1 $outputFile).Trim()
    $duration = 0.0
    [void][double]::TryParse(
        $durationText,
        [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$duration
    )
    $expected = [int](($group.End - $group.Start).TotalSeconds)
    if ([math]::Abs($duration - $expected) -gt 3) {
        throw "Merged duration mismatch: $outputFile actual=$duration expected=$expected"
    }
    if ($FullDecode) {
        & $FFmpeg -hide_banner -v error -i $outputFile -f null -
        if ($LASTEXITCODE -ne 0) {
            throw "Merged file decode failed: $outputFile"
        }
    }
    $results.Add([pscustomobject]@{
        File = $outputFile
        Duration = [math]::Round($duration, 3)
        SizeMB = [math]::Round((Get-Item -LiteralPath $outputFile).Length / 1MB, 1)
    })
}

$results | Format-Table -AutoSize
exit 0
