[CmdletBinding()]
param(
    [string]$InputDirectory = "F:\Hi8",

    [string]$IndexFile = "",

    [string]$ReportFile = "",

    [ValidateRange(30, 600)]
    [int]$TailSeconds = 120,

    [ValidateRange(1, 600)]
    [int]$ExpectedBlackTailSeconds = 40,

    [ValidateRange(1, 360)]
    [int]$MinimumExpectedDurationMinutes = 50,

    [switch]$SkipDecodeCheck,

    [switch]$CreateHashes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-CommandAvailable {
    param([Parameter(Mandatory = $true)][string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-TapeLabel {
    param([Parameter(Mandatory = $true)][string]$Name)

    if ($Name -match '(?i)\s-\s(?<label>C\d{1,2})\.mkv$') {
        return ('C{0:00}' -f [int]$Matches.label.Substring(1))
    }

    return $null
}

function Get-CaptureStart {
    param([Parameter(Mandatory = $true)][string]$Name)

    if ($Name -match '^hi8-capture-(?<date>\d{4}-\d{2}-\d{2})_(?<time>\d{2}-\d{2}-\d{2})') {
        return [DateTime]::ParseExact(
            "$($Matches.date) $($Matches.time)",
            'yyyy-MM-dd HH-mm-ss',
            [Globalization.CultureInfo]::InvariantCulture
        )
    }

    return $null
}

function Get-IndexEntries {
    param([Parameter(Mandatory = $true)][string]$Path)

    $entries = @{}
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Warning "Index file not found; the report will not include descriptions: $Path"
        return $entries
    }

    foreach ($line in Get-Content -LiteralPath $Path) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $columns = $line -split "`t", 2
        $baseName = $columns[0].Trim()
        $label = Get-TapeLabel -Name ($baseName + '.mkv')
        $entry = [pscustomobject]@{
            Tape        = $label
            Description = if ($columns.Count -gt 1) { $columns[1].Trim() } else { "" }
        }
        $entries[$baseName] = $entry

        # A first capture can lack its tape suffix when -TapeLabel was omitted.
        # Its timestamp still matches the index entry once the " - Cnn" suffix
        # is removed.
        if ($baseName -match '^(?<capture>hi8-capture-\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2})\s-\sC\d{1,2}$') {
            $entries[$Matches.capture] = $entry
        }
    }

    return $entries
}

function Get-ProbeData {
    param([Parameter(Mandatory = $true)][System.IO.FileInfo]$File)

    $json = & ffprobe -v error -show_entries format=duration,size -show_entries stream=codec_type,codec_name,width,height,r_frame_rate -of json -- $File.FullName 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "ffprobe failed: $($json -join ' ')"
    }

    return ($json -join "`n" | ConvertFrom-Json)
}

function Get-TailBlackSeconds {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileInfo]$File,
        [Parameter(Mandatory = $true)][double]$Duration,
        [Parameter(Mandatory = $true)][int]$Seconds
    )

    # One frame per second is sufficient here: this is a triage check, not a
    # frame-accurate edit decision. blackframe emits only while the picture is black.
    # metadata=print:file=- writes just the blackframe metadata to stdout.
    # Keeping FFmpeg's normal diagnostics off stderr avoids PowerShell treating
    # informational lines as errors under $ErrorActionPreference = 'Stop'.
    $output = & ffmpeg -hide_banner -v error -sseof ("-{0}" -f $Seconds) -i $File.FullName -an -vf "fps=1,blackframe=98:32,metadata=print:file=-" -f null NUL 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "tail analysis failed: $($output -join ' ')"
    }

    $timestamps = [System.Collections.Generic.List[double]]::new()
    foreach ($line in $output) {
        $text = [string]$line
        if ($text -match 'pts_time:(?<seconds>-?\d+(?:\.\d+)?)') {
            $timestamps.Add([double]::Parse($Matches.seconds, [Globalization.CultureInfo]::InvariantCulture))
        }
    }

    if ($timestamps.Count -eq 0) { return 0.0 }

    $timestamps = @($timestamps | Sort-Object -Unique)
    $lastTimestamp = $timestamps[-1]
    # With -sseof, FFmpeg restarts filter timestamps at zero. A final black
    # run has to reach the end of the analysed tail, allowing two seconds for
    # the 1 fps sampling.
    $analysedDuration = [math]::Min($Duration, [double]$Seconds)
    if (($analysedDuration - $lastTimestamp) -gt 2.5) { return 0.0 }

    $runStart = $lastTimestamp
    for ($position = $timestamps.Count - 2; $position -ge 0; $position--) {
        if (($timestamps[$position + 1] - $timestamps[$position]) -gt 2.5) { break }
        $runStart = $timestamps[$position]
    }

    return [math]::Max(0, $analysedDuration - $runStart)
}

function Test-FullDecode {
    param([Parameter(Mandatory = $true)][System.IO.FileInfo]$File)

    $output = & ffmpeg -hide_banner -v error -xerror -i $File.FullName -map 0:v:0 -map '0:a?' -f null NUL 2>&1
    return [pscustomobject]@{
        Passed = ($LASTEXITCODE -eq 0)
        Error  = if ($LASTEXITCODE -eq 0) { "" } else { ($output -join ' ').Trim() }
    }
}

if (-not (Test-CommandAvailable ffmpeg) -or -not (Test-CommandAvailable ffprobe)) {
    throw "ffmpeg and ffprobe must both be available on PATH."
}

$inputItem = Get-Item -LiteralPath $InputDirectory -ErrorAction Stop
if (-not $inputItem.PSIsContainer) { throw "InputDirectory is not a directory: $InputDirectory" }
$InputDirectory = $inputItem.FullName

if ([string]::IsNullOrWhiteSpace($IndexFile)) { $IndexFile = Join-Path $InputDirectory 'index.txt' }
if ([string]::IsNullOrWhiteSpace($ReportFile)) { $ReportFile = Join-Path $InputDirectory 'hi8-audit.csv' }

$indexEntries = Get-IndexEntries -Path $IndexFile
$files = @(Get-ChildItem -LiteralPath $InputDirectory -Filter '*.mkv' -File | Sort-Object Name)
if ($files.Count -eq 0) { throw "No MKV files found in $InputDirectory" }

$captures = foreach ($file in $files) {
    $tapeLabel = Get-TapeLabel -Name $file.Name
    $baseName = [IO.Path]::GetFileNameWithoutExtension($file.Name)
    $indexEntry = if ($indexEntries.ContainsKey($baseName)) { $indexEntries[$baseName] } else { $null }
    if (-not $tapeLabel -and $indexEntry) { $tapeLabel = $indexEntry.Tape }
    $probe = $null
    $duration = 0.0
    $probeError = ""
    $tailBlack = 0.0
    $tailError = ""

    try {
        $probe = Get-ProbeData -File $file
        $duration = [double]::Parse($probe.format.duration, [Globalization.CultureInfo]::InvariantCulture)
        $tailBlack = Get-TailBlackSeconds -File $file -Duration $duration -Seconds $TailSeconds
    }
    catch {
        $probeError = $_.Exception.Message
    }

    $decode = [pscustomobject]@{ Passed = $null; Error = "Skipped" }
    if (-not $SkipDecodeCheck -and [string]::IsNullOrEmpty($probeError)) {
        Write-Host "Full decode check: $($file.Name)"
        $decode = Test-FullDecode -File $file
    }

    [pscustomobject]@{
        Tape              = $tapeLabel
        File              = $file.Name
        CaptureStart      = Get-CaptureStart -Name $file.Name
        Description       = if ($indexEntry) { $indexEntry.Description } else { "" }
        DurationSeconds   = [math]::Round($duration, 3)
        Duration          = if ($duration -gt 0) { [TimeSpan]::FromSeconds($duration).ToString('hh\:mm\:ss') } else { "" }
        SizeBytes         = $file.Length
        Video             = if ($probe) { (($probe.streams | Where-Object codec_type -eq 'video' | Select-Object -First 1).codec_name) } else { "" }
        Audio             = if ($probe) { (($probe.streams | Where-Object codec_type -eq 'audio' | Select-Object -First 1).codec_name) } else { "" }
        TailBlackSeconds  = [math]::Round($tailBlack, 1)
        DecodeCheck       = if ($SkipDecodeCheck) { 'SKIPPED' } elseif ($decode.Passed) { 'OK' } else { 'ERROR' }
        Error             = if ($probeError) { $probeError } else { $decode.Error }
    }
}

$minimumSeconds = $MinimumExpectedDurationMinutes * 60
$report = foreach ($group in ($captures | Group-Object { if ($_.Tape) { $_.Tape } else { "UNLABELLED: $($_.File)" } } | Sort-Object Name)) {
    $items = @($group.Group | Sort-Object File)
    $duration = ($items | Measure-Object DurationSeconds -Sum).Sum
    $tailBlack = $items[-1].TailBlackSeconds
    $decodeError = @($items | Where-Object DecodeCheck -eq 'ERROR')
    $reasons = [System.Collections.Generic.List[string]]::new()

    if ($decodeError.Count -gt 0) { $reasons.Add('DECODE_ERROR') }
    if ($items.Tape -contains $null) { $reasons.Add('UNLABELLED_FILE') }
    if ($tailBlack -lt $ExpectedBlackTailSeconds) { $reasons.Add('CHECK_END') }
    if ($duration -lt $minimumSeconds) { $reasons.Add('CHECK_SHORT') }
    if ($items.Count -gt 1) { $reasons.Add('SPLIT_CAPTURE') }

    $continuity = [System.Collections.Generic.List[string]]::new()
    for ($position = 0; $position -lt ($items.Count - 1); $position++) {
        $current = $items[$position]
        $next = $items[$position + 1]
        if ($null -eq $current.CaptureStart -or $null -eq $next.CaptureStart) {
            $continuity.Add('UNKNOWN_START_TIME')
            continue
        }

        $wallGap = ($next.CaptureStart - $current.CaptureStart.AddSeconds($current.DurationSeconds)).TotalSeconds
        $unexplainedGap = [math]::Max(0, $wallGap - $current.TailBlackSeconds)
        if ($unexplainedGap -gt 10) {
            $reasons.Add('CHECK_SPLIT_GAP')
            $continuity.Add(('CHECK: {0:N0}s between files; {1:N0}s after prior black tail' -f $wallGap, $unexplainedGap))
        }
        else {
            $continuity.Add(('OK: {0:N0}s between files; covered by prior {1:N0}s black tail' -f $wallGap, $current.TailBlackSeconds))
        }
    }
    if ($reasons.Count -eq 0) { $reasons.Add('OK') }

    [pscustomobject]@{
        Tape                 = $items[0].Tape
        Status               = $reasons -join ';'
        CaptureCount         = $items.Count
        TotalDurationSeconds = [math]::Round($duration, 3)
        TotalDuration        = [TimeSpan]::FromSeconds($duration).ToString('hh\:mm\:ss')
        FinalTailBlackSeconds = $tailBlack
        SplitContinuity      = $continuity -join ' | '
        DecodeCheck          = if ($decodeError.Count -gt 0) { 'ERROR' } elseif ($SkipDecodeCheck) { 'SKIPPED' } else { 'OK' }
        Files                = $items.File -join ' | '
        Description          = ($items.Description | Where-Object { $_ } | Select-Object -First 1)
        Error                = (@($decodeError | ForEach-Object { $_.Error } | Where-Object { $_ -and $_ -ne 'Skipped' })) -join ' | '
    }
}

$report | Export-Csv -LiteralPath $ReportFile -NoTypeInformation -Encoding UTF8
$captures | Export-Csv -LiteralPath ([IO.Path]::ChangeExtension($ReportFile, '.captures.csv')) -NoTypeInformation -Encoding UTF8

if ($CreateHashes) {
    $hashFile = Join-Path $InputDirectory 'hi8-sha256.csv'
    Get-FileHash -LiteralPath ($files.FullName) -Algorithm SHA256 |
        Select-Object Path, Hash |
        Export-Csv -LiteralPath $hashFile -NoTypeInformation -Encoding UTF8
    Write-Host "SHA-256 manifest: $hashFile"
}

Write-Host ""
Write-Host "Audit report: $ReportFile"
$report | Format-Table Tape, Status, TotalDuration, FinalTailBlackSeconds, CaptureCount -AutoSize
Write-Host ""
Write-Host "CHECK_SHORT means only that the capture is shorter than $MinimumExpectedDurationMinutes minutes; it is not proof that material is missing."
Write-Host "CHECK_END means the expected final black run was not found; inspect that tape's end before trimming anything."
