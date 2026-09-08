[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$InputFile,
    [Parameter(Mandatory = $true)][string]$AnalysisDirectory,
    [ValidateRange(0.1, 2.0)][double]$BridgeRatio = 1.10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$source = Get-Item -LiteralPath $InputFile
if ($source.PSIsContainer) { throw 'InputFile must be a video file.' }
$ffmpeg = (Get-Command ffmpeg -ErrorAction Stop).Source
$ffprobe = (Get-Command ffprobe -ErrorAction Stop).Source
$metadataText = & $ffprobe -v error -select_streams v:0 -show_entries stream=avg_frame_rate:format=duration -of json $source.FullName
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect input video.' }
$metadata = ($metadataText -join "`n") | ConvertFrom-Json
if ($metadata.streams.Count -ne 1 -or $metadata.streams[0].avg_frame_rate -ne '50/1') {
    throw 'This workflow supports uniform 50 fps video only. Do not force a variable-rate capture into this repair.'
}
$duration = [double]::Parse($metadata.format.duration, [Globalization.CultureInfo]::InvariantCulture)
if ($duration * 50 * 3072 -ge [int]::MaxValue) { throw 'Analysis exceeds the in-memory detector limit; analyse a shorter source.' }
$directory = [IO.Path]::GetFullPath($AnalysisDirectory)
if (Test-Path -LiteralPath $directory) {
    if (-not (Test-Path -LiteralPath $directory -PathType Container) -or @(Get-ChildItem -LiteralPath $directory -Force).Count) {
        throw 'AnalysisDirectory must be absent or empty.'
    }
} else { $null = New-Item -ItemType Directory -Path $directory }

# Keep millisecond timing, rather than quantizing irregular frames to 50 Hz.
# Relative tee outputs avoid escaping Windows drive letters in tee syntax.
Push-Location -LiteralPath $directory
try {
    & $ffmpeg -hide_banner -nostdin -loglevel error -n -copyts -i $source.FullName `
        -map 0:v:0 -vf 'scale=64:48' -pix_fmt gray -c:v rawvideo `
        -enc_time_base:v '1:1000' -fps_mode passthrough -f tee `
        '[f=rawvideo]analysis.gray|[f=framehash]analysis.framehash'
    if ($LASTEXITCODE -ne 0) { throw 'Frame extraction failed; analysis is incomplete.' }
} finally { Pop-Location }
$frameCount = 0
$firstPts = $null
foreach ($row in [IO.File]::ReadLines((Join-Path $directory 'analysis.framehash'))) {
    if ($row.StartsWith('#')) { continue }
    $fields = $row.Split(',')
    if ($fields.Length -lt 6) { continue }
    $pts = [long]::Parse($fields[2].Trim(), [Globalization.CultureInfo]::InvariantCulture)
    if ($null -eq $firstPts) { $firstPts = $pts }
    if ($pts -ne ($firstPts + 20 * $frameCount)) { throw "Non-uniform timestamps at frame $frameCount; repair is not supported." }
    $frameCount++
}
if ($frameCount -lt 2 -or (Get-Item (Join-Path $directory 'analysis.gray')).Length -ne $frameCount * 3072L) {
    throw 'Incomplete analysis frames.'
}
if ($firstPts % 20 -ne 0) { throw 'Video starts off the 20 ms output grid; this repair would shift timing and is not supported.' }
if ($null -eq ('FlashRepairAnalysis' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'FlashRepairAnalysis.cs') }
$candidatesPath = Join-Path $directory 'candidates.csv'
$null = [FlashRepairAnalysis]::Scan((Join-Path $directory 'analysis.gray'), $candidatesPath, 50, $BridgeRatio)
$merged = [Collections.Generic.List[object]]::new()
foreach ($row in Import-Csv -LiteralPath $candidatesPath) {
    $first = [int]$row.first_frame
    $last = [int]$row.last_frame
    if ($merged.Count -and $first -le $merged[$merged.Count - 1].last_frame + 1) {
        $merged[$merged.Count - 1].last_frame = [Math]::Max($last, $merged[$merged.Count - 1].last_frame)
    } else {
        $merged.Add([pscustomobject]@{ first_frame = $first; last_frame = $last })
    }
}
$episodesPath = Join-Path $directory 'episodes.csv'
if ($merged.Count) { $merged | Export-Csv -LiteralPath $episodesPath -NoTypeInformation -Encoding UTF8 }
else { 'first_frame,last_frame' | Set-Content -LiteralPath $episodesPath -Encoding ASCII }
[pscustomobject]@{
    Path = $source.FullName; Length = $source.Length; LastWriteTimeUtc = $source.LastWriteTimeUtc.ToString('o')
    FrameRate = 50; FrameCount = $frameCount; UniformFrameGrid = $true
    VideoStartSeconds = $firstPts / 1000.0; BridgeRatio = $BridgeRatio
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $directory 'source.json') -Encoding UTF8
Write-Output "Analysis complete: $frameCount frames, $($merged.Count) candidate intervals. Review episodes.csv before repair."
