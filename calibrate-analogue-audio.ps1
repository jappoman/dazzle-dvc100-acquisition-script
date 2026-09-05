[CmdletBinding()]
param(
    [string]$InputDirectory = 'F:\Hi8\ok',

    [ValidateRange(10, 120)]
    [int]$SampleSeconds = 40,

    [string]$ReportFile = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($null -eq (Get-Command ffmpeg -ErrorAction SilentlyContinue) -or
    $null -eq (Get-Command ffprobe -ErrorAction SilentlyContinue)) {
    throw 'ffmpeg and ffprobe must be available on PATH.'
}

$directory = Get-Item -LiteralPath $InputDirectory -ErrorAction Stop
if (-not $directory.PSIsContainer) { throw "InputDirectory is not a directory: $InputDirectory" }
if ([string]::IsNullOrWhiteSpace($ReportFile)) {
    $ReportFile = Join-Path $directory.FullName 'analogue-audio-calibration.csv'
}

function Get-VolumeStats {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    # FFmpeg writes filter statistics to stderr. Capture them without making
    # informational messages terminating PowerShell errors.
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & ffmpeg @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    if ($exitCode -ne 0) { throw "ffmpeg returned $exitCode" }
    $text = @($output | ForEach-Object { [string]$_ })
    $mean = @($text | Where-Object { $_ -match 'mean_volume:\s*(?<value>-?\d+(?:\.\d+)?) dB' })[-1]
    $maximum = @($text | Where-Object { $_ -match 'max_volume:\s*(?<value>-?\d+(?:\.\d+)?) dB' })[-1]

    return [pscustomobject]@{
        MeanDb = if ($mean -match 'mean_volume:\s*(?<value>-?\d+(?:\.\d+)?) dB') { [double]$Matches.value } else { $null }
        MaxDb  = if ($maximum -match 'max_volume:\s*(?<value>-?\d+(?:\.\d+)?) dB') { [double]$Matches.value } else { $null }
    }
}

$files = @(Get-ChildItem -LiteralPath $directory.FullName -Filter '*.mkv' -File | Sort-Object Name)
if ($files.Count -eq 0) { throw "No MKV files found in $($directory.FullName)" }

$results = foreach ($file in $files) {
    $durationText = & ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $file.FullName
    if ($LASTEXITCODE -ne 0) { throw "ffprobe failed for $($file.Name)" }
    $duration = [double]::Parse($durationText, [Globalization.CultureInfo]::InvariantCulture)
    $contentStart = [math]::Max(0, [math]::Min($duration - $SampleSeconds, $duration * 0.25))

    Write-Host "Measuring $($file.Name)"
    $tail = Get-VolumeStats -Arguments @(
        '-hide_banner'; '-sseof'; "-$SampleSeconds"; '-i'; $file.FullName
        '-vn'; '-af'; 'volumedetect'; '-f'; 'null'; 'NUL'
    )
    $content = Get-VolumeStats -Arguments @(
        '-hide_banner'; '-ss'; ([math]::Round($contentStart, 3).ToString([Globalization.CultureInfo]::InvariantCulture)); '-t'; "$SampleSeconds"; '-i'; $file.FullName
        '-vn'; '-af'; 'volumedetect'; '-f'; 'null'; 'NUL'
    )

    [pscustomobject]@{
        File              = $file.Name
        Duration           = [TimeSpan]::FromSeconds($duration).ToString('hh\:mm\:ss')
        TailMeanDb         = $tail.MeanDb
        TailMaxDb          = $tail.MaxDb
        ContentMeanDb      = $content.MeanDb
        ContentMaxDb       = $content.MaxDb
        PeakSeparationDb   = if ($null -ne $tail.MaxDb -and $null -ne $content.MaxDb) { [math]::Round($content.MaxDb - $tail.MaxDb, 1) } else { $null }
    }
}

$results | Export-Csv -LiteralPath $ReportFile -NoTypeInformation -Encoding UTF8
$results | Format-Table File, TailMeanDb, TailMaxDb, ContentMeanDb, ContentMaxDb, PeakSeparationDb -AutoSize
Write-Host "Report: $ReportFile"
