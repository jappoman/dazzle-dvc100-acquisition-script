[CmdletBinding()]
param(
    [string]$InputDirectory = 'F:\DazzleCapture\master',

    [AllowEmptyString()]
    [string]$OutputDirectory = '',

    [ValidateRange(5, 600)]
    [int]$MinimumBlackSeconds = 10,

    [ValidateRange(1, 60)]
    [int]$KeepBlackSeconds = 5,

    [ValidateSet('Hi8', 'VHS')]
    [string]$SignalProfile = 'Hi8',

    [double]$SilenceThresholdDb = -20,

    [ValidateRange(1, 30)]
    [int]$VhsMergeSilenceGapSeconds = 5,

    [ValidateRange(10, 120)]
    [int]$VhsEvidenceWindowSeconds = 30,

    [ValidateRange(0.1, 1.0)]
    [double]$VhsMinimumBlackRatio = 0.4,

    [ValidateRange(0, 120)]
    [int]$VhsSilenceLeadInSeconds = 45
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($null -eq (Get-Command ffmpeg -ErrorAction SilentlyContinue) -or
    $null -eq (Get-Command ffprobe -ErrorAction SilentlyContinue)) {
    throw 'ffmpeg and ffprobe must be available on PATH.'
}

$input = Get-Item -LiteralPath $InputDirectory -ErrorAction Stop
if (-not $input.PSIsContainer) { throw "InputDirectory is not a directory: $InputDirectory" }
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Split-Path -Path $input.FullName -Parent
}
$outputExists = Test-Path -LiteralPath $OutputDirectory
if ($outputExists) {
    $outputItem = Get-Item -LiteralPath $OutputDirectory -ErrorAction Stop
    if (-not $outputItem.PSIsContainer) { throw "OutputDirectory is not a directory: $OutputDirectory" }
    if ($outputItem.FullName.TrimEnd('\\') -eq $input.FullName.TrimEnd('\\')) {
        throw 'OutputDirectory must be different from InputDirectory.'
    }
    $existingMedia = @(Get-ChildItem -LiteralPath $outputItem.FullName -File -Filter '*.mkv')
    if ($existingMedia.Count -gt 0 -or (Test-Path -LiteralPath (Join-Path $outputItem.FullName 'catalogo-cassette.csv'))) {
        throw "OutputDirectory already contains finalised media or a catalogue: $OutputDirectory"
    }
}

$files = @(Get-ChildItem -LiteralPath $input.FullName -File -Filter '*.mkv' | Sort-Object Name)
if ($files.Count -eq 0) { throw "No MKV files found in $($input.FullName)" }

function Get-FinalFileName {
    param([Parameter(Mandatory = $true)][System.IO.FileInfo]$File)
    $label = $File.BaseName
    if ($label -match '^dazzle-capture-\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2} - (?<label>.+)$') {
        $label = $Matches.label.Trim()
    }
    if ([string]::IsNullOrWhiteSpace($label) -or $label.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
        $label -match '[. ]$' -or $label -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
        throw "Invalid tape label for output filename: $label"
    }
    return "$label.mkv"
}

# Detect repeated labels before scanning or writing any video. Never overwrite
# one capture with another continuation carrying the same tape label.
$finalNames = @{}
$seenNames = @{}
foreach ($file in $files) {
    $name = Get-FinalFileName -File $file
    if ($seenNames.ContainsKey($name)) { throw "Multiple captures have output label '$name'; select or combine them explicitly first." }
    $seenNames[$name] = $true
    $finalNames[$file.FullName] = $name
}

function Convert-ToFfmpegSeconds {
    param([Parameter(Mandatory = $true)][double]$Value)
    return $Value.ToString('0.###', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-DurationSeconds {
    param([Parameter(Mandatory = $true)][System.IO.FileInfo]$File)
    $value = & ffprobe -v error -show_entries format=duration -of default=nk=1:nw=1 -- $File.FullName
    if ($LASTEXITCODE -ne 0) { throw "ffprobe failed: $($File.Name)" }
    return [double]::Parse($value, [Globalization.CultureInfo]::InvariantCulture)
}

function Get-BlackSamples {
    param([Parameter(Mandatory = $true)][System.IO.FileInfo]$File)

    # One sample per second makes the decision reliable for multi-second tape
    # gaps without the unnecessary cost of decoding every captured frame.
    $output = & ffmpeg -hide_banner -v error -i $File.FullName -an `
        -vf 'fps=1,blackframe=98:32,metadata=print:file=-' -f null NUL 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Black-frame scan failed: $($File.Name)" }

    $timestamps = [System.Collections.Generic.List[double]]::new()
    foreach ($line in $output) {
        if ([string]$line -match 'pts_time:(?<value>-?\d+(?:\.\d+)?)') {
            $timestamps.Add([double]::Parse($Matches.value, [Globalization.CultureInfo]::InvariantCulture))
        }
    }
    return @($timestamps | Sort-Object -Unique)
}

function Convert-BlackSamplesToRuns {
    param([Parameter(Mandatory = $true)][double[]]$Samples)
    if ($Samples.Count -eq 0) { return @() }

    $runs = [System.Collections.Generic.List[object]]::new()
    $start = $Samples[0]
    $last = $Samples[0]
    for ($position = 1; $position -lt $Samples.Count; $position++) {
        if (($Samples[$position] - $last) -gt 2.5) {
            $runs.Add([pscustomobject]@{ Start = $start; End = $last; Seconds = $last - $start + 1 })
            $start = $Samples[$position]
        }
        $last = $Samples[$position]
    }
    $runs.Add([pscustomobject]@{ Start = $start; End = $last; Seconds = $last - $start + 1 })
    return @($runs)
}

function Get-SilenceRuns {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileInfo]$File,
        [Parameter(Mandatory = $true)][double]$Duration
    )

    $threshold = $SilenceThresholdDb.ToString([Globalization.CultureInfo]::InvariantCulture)
    # FFmpeg writes silencedetect metadata to stderr. Temporarily allow that
    # informational stream to be collected instead of letting StrictMode turn
    # it into a PowerShell NativeCommandError.
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & ffmpeg -hide_banner -v info -i $File.FullName -vn `
            -af "silencedetect=n=${threshold}dB:d=2" -f null NUL 2>&1
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($LASTEXITCODE -ne 0) { throw "Audio silence scan failed: $($File.Name)" }

    $runs = [System.Collections.Generic.List[object]]::new()
    $start = $null
    foreach ($line in $output) {
        $text = [string]$line
        if ($text -match 'silence_start:\s*(?<value>-?\d+(?:\.\d+)?)') {
            $start = [double]::Parse($Matches.value, [Globalization.CultureInfo]::InvariantCulture)
        }
        elseif ($text -match 'silence_end:\s*(?<end>-?\d+(?:\.\d+)?)') {
            if ($null -ne $start) {
                $end = [double]::Parse($Matches.end, [Globalization.CultureInfo]::InvariantCulture)
                $runs.Add([pscustomobject]@{ Start = $start; End = $end; Seconds = $end - $start })
                $start = $null
            }
        }
    }
    if ($null -ne $start) {
        $runs.Add([pscustomobject]@{ Start = $start; End = $Duration; Seconds = $Duration - $start })
    }
    return @($runs)
}

function Merge-Runs {
    param(
        [Parameter(Mandatory = $true)][object[]]$Runs,
        [Parameter(Mandatory = $true)][double]$MaximumGapSeconds
    )
    if ($Runs.Count -eq 0) { return @() }

    $ordered = @($Runs | Sort-Object Start)
    $merged = [System.Collections.Generic.List[object]]::new()
    $start = [double]$ordered[0].Start
    $end = [double]$ordered[0].End
    for ($position = 1; $position -lt $ordered.Count; $position++) {
        if (([double]$ordered[$position].Start - $end) -le $MaximumGapSeconds) {
            $end = [Math]::Max($end, [double]$ordered[$position].End)
        }
        else {
            $merged.Add([pscustomobject]@{ Start = $start; End = $end; Seconds = $end - $start })
            $start = [double]$ordered[$position].Start
            $end = [double]$ordered[$position].End
        }
    }
    $merged.Add([pscustomobject]@{ Start = $start; End = $end; Seconds = $end - $start })
    return @($merged)
}

function Get-VhsNoSignalRuns {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileInfo]$File,
        [Parameter(Mandatory = $true)][double]$Duration,
        [Parameter(Mandatory = $true)][double[]]$BlackSamples
    )

    # VHS end-of-tape signal is often noisy rather than continuously black.
    # Require long, nearly continuous silence plus a dense black-frame pattern
    # somewhere in the same interval. If that pattern appears promptly, retain
    # the start of silence; otherwise start at the first visual evidence.
    $silentRuns = Merge-Runs -Runs (Get-SilenceRuns -File $File -Duration $Duration) `
        -MaximumGapSeconds $VhsMergeSilenceGapSeconds
    $minimumSamples = [Math]::Ceiling($VhsEvidenceWindowSeconds * $VhsMinimumBlackRatio)
    $detected = [System.Collections.Generic.List[object]]::new()

    foreach ($silentRun in $silentRuns) {
        if ($silentRun.Seconds -lt $MinimumBlackSeconds) { continue }
        $samples = @($BlackSamples | Where-Object { $_ -ge $silentRun.Start -and $_ -le $silentRun.End })
        if ($samples.Count -eq 0) { continue }

        $left = 0
        $hasEvidence = $false
        for ($right = 0; $right -lt $samples.Count; $right++) {
            while (($samples[$right] - $samples[$left]) -gt $VhsEvidenceWindowSeconds) { $left++ }
            if (($right - $left + 1) -ge $minimumSamples) { $hasEvidence = $true; break }
        }
        if (-not $hasEvidence) { continue }

        $start = if (($samples[0] - $silentRun.Start) -le $VhsSilenceLeadInSeconds) {
            $silentRun.Start
        }
        else {
            $samples[0]
        }
        $detected.Add([pscustomobject]@{ Start = $start; End = $silentRun.End; Seconds = $silentRun.End - $start })
    }
    return @(Merge-Runs -Runs $detected.ToArray() -MaximumGapSeconds $VhsMergeSilenceGapSeconds)
}

function New-StreamCopySegment {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][double]$Start,
        [Parameter(Mandatory = $true)][double]$End,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $duration = $End - $Start
    if ($duration -le 0.1) { throw "Invalid output segment: $Destination" }
    & ffmpeg -hide_banner -y -ss (Convert-ToFfmpegSeconds $Start) -t (Convert-ToFfmpegSeconds $duration) `
        -i $Source -map 0 -c copy -avoid_negative_ts make_zero $Destination
    if ($LASTEXITCODE -ne 0) { throw "Stream-copy cut failed: $Destination" }
}

function Join-StreamCopySegments {
    param(
        [Parameter(Mandatory = $true)][string[]]$Segments,
        [Parameter(Mandatory = $true)][string]$ListFile,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $lines = $Segments | ForEach-Object { "file '$($_.Replace("'", "'\\''"))'" }
    [IO.File]::WriteAllLines($ListFile, $lines, [Text.UTF8Encoding]::new($false))
    & ffmpeg -hide_banner -y -f concat -safe 0 -i $ListFile -map 0 -c copy $Destination
    if ($LASTEXITCODE -ne 0) { throw "Stream-copy join failed: $Destination" }
}

function Get-IndexDescriptions {
    param([Parameter(Mandatory = $true)][string]$Directory)
    $path = Join-Path $Directory 'index.txt'
    $entries = @{}
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $entries }
    foreach ($line in Get-Content -LiteralPath $path -Encoding UTF8) {
        $columns = $line -split "`t", 2
        if ($columns.Count -gt 1) { $entries[$columns[0].Trim()] = $columns[1].Trim() }
    }
    return $entries
}

if (-not $outputExists) {
    New-Item -ItemType Directory -Path $OutputDirectory -ErrorAction Stop | Out-Null
}
$workDirectory = Join-Path $OutputDirectory '_temporanei'
New-Item -ItemType Directory -Path $workDirectory -ErrorAction Stop | Out-Null
$descriptions = Get-IndexDescriptions -Directory $input.FullName
$catalogue = [System.Collections.Generic.List[object]]::new()

try {
    foreach ($file in $files) {
        Write-Host "Analysing $($file.Name) ($SignalProfile profile)"
        $duration = Get-DurationSeconds -File $file
        $blackSamples = @(Get-BlackSamples -File $file)
        $runs = if ($SignalProfile -eq 'VHS') {
            @(Get-VhsNoSignalRuns -File $file -Duration $duration -BlackSamples $blackSamples)
        }
        else {
            @(Convert-BlackSamplesToRuns -Samples $blackSamples | Where-Object { $_.Seconds -ge $MinimumBlackSeconds })
        }
        $terminalRuns = @($runs | Where-Object { ($duration - $_.End) -le 2.5 })
        $finalRun = if ($terminalRuns.Count) { $terminalRuns[-1] } else { $null }
        $internalRuns = @($runs | Where-Object { $null -eq $finalRun -or $_.Start -ne $finalRun.Start } | Sort-Object Start)

        $segments = [System.Collections.Generic.List[object]]::new()
        $cursor = 0.0
        foreach ($run in $internalRuns) {
            # Preserve the first KeepBlackSeconds seconds of each gap, then
            # resume after its final black sample.
            $segmentEnd = [Math]::Min($run.Start + $KeepBlackSeconds, $duration)
            if (($segmentEnd - $cursor) -gt 0.1) {
                $segments.Add([pscustomobject]@{ Start = $cursor; End = $segmentEnd })
            }
            $cursor = [Math]::Max($cursor, $run.End + 1)
        }
        $lastEnd = if ($null -ne $finalRun) {
            [Math]::Min($duration, $finalRun.Start + $KeepBlackSeconds)
        } else { $duration }
        if (($lastEnd - $cursor) -gt 0.1) {
            $segments.Add([pscustomobject]@{ Start = $cursor; End = $lastEnd })
        }
        if ($segments.Count -eq 0) { throw "No output segments planned for $($file.Name)" }

        $finalName = $finalNames[$file.FullName]
        $destination = Join-Path $OutputDirectory $finalName
        if ($segments.Count -eq 1) {
            New-StreamCopySegment -Source $file.FullName -Start $segments[0].Start -End $segments[0].End -Destination $destination
        } else {
            $segmentPaths = [System.Collections.Generic.List[string]]::new()
            for ($position = 0; $position -lt $segments.Count; $position++) {
                $segmentPath = Join-Path $workDirectory ('{0}-{1:D2}.mkv' -f $file.BaseName, $position + 1)
                New-StreamCopySegment -Source $file.FullName -Start $segments[$position].Start -End $segments[$position].End -Destination $segmentPath
                $segmentPaths.Add($segmentPath)
            }
            $listFile = Join-Path $workDirectory ($file.BaseName + '.ffconcat')
            Join-StreamCopySegments -Segments $segmentPaths.ToArray() -ListFile $listFile -Destination $destination
        }

        $finalDuration = Get-DurationSeconds -File (Get-Item -LiteralPath $destination)
        $time = [TimeSpan]::FromSeconds([Math]::Round($finalDuration))
        $catalogue.Add([pscustomobject][ordered]@{
            File = $finalName
            Contenuto = if ($descriptions.ContainsKey($file.BaseName)) {
                $descriptions[$file.BaseName]
            } elseif ($descriptions.ContainsKey([IO.Path]::GetFileNameWithoutExtension($finalName))) {
                $descriptions[[IO.Path]::GetFileNameWithoutExtension($finalName)]
            } else { '' }
            Durata = ('{0:D2}:{1:D2}:{2:D2}' -f $time.Hours, $time.Minutes, $time.Seconds)
        })
    }

    $catalogue | Export-Csv -LiteralPath (Join-Path $OutputDirectory 'catalogo-cassette.csv') -Delimiter ';' -NoTypeInformation -Encoding utf8
}
finally {
    if (Test-Path -LiteralPath $workDirectory) {
        Remove-Item -LiteralPath $workDirectory -Recurse -Force
    }
}

Write-Host "Complete. Finalised copies and catalog: $OutputDirectory"
