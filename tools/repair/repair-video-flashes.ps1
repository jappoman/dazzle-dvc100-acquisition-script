[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$AnalysisDirectory,
    [Parameter(Mandatory = $true)][string]$OutputFile,
    [ValidateSet('superfast', 'veryfast')][string]$Preset = 'superfast',
    [switch]$PrepareOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$analysis = (Resolve-Path -LiteralPath $AnalysisDirectory).Path
$source = Get-Content -LiteralPath (Join-Path $analysis 'source.json') -Raw | ConvertFrom-Json
$inputItem = Get-Item -LiteralPath $source.Path
if ($inputItem.Length -ne $source.Length -or $inputItem.LastWriteTimeUtc.ToString('o') -ne $source.LastWriteTimeUtc) {
    throw 'Source changed since analysis; regenerate the analysis before repair.'
}
if ($source.FrameRate -ne 50 -or -not $source.UniformFrameGrid) {
    throw 'This repair requires the verified uniform 50 fps frame grid.'
}
$outputPath = [IO.Path]::GetFullPath($OutputFile)
if (Test-Path -LiteralPath $outputPath) { throw 'Output already exists; choose a new filename.' }
if ($inputItem.FullName -eq $outputPath) { throw 'Cannot overwrite source.' }
$outputDirectory = Split-Path -Parent $outputPath
$null = New-Item -ItemType Directory -Path $outputDirectory -Force
$episodes = @(Import-Csv -LiteralPath (Join-Path $analysis 'episodes.csv'))
if ($episodes.Count -eq 0) { throw 'No detection intervals to repair.' }
$previousLast = -1
$replacedFrames = 0
foreach ($episode in $episodes) {
    $first = [int]$episode.first_frame
    $last = [int]$episode.last_frame
    if ($first -le 0 -or $first -le ($previousLast + 1) -or $last -lt $first -or $last -ge ($source.FrameCount - 1)) {
        throw 'Invalid, overlapping, unsorted or edge-of-video interval.'
    }
    $replacedFrames += $last - $first + 1
    $previousLast = $last
}

function New-SelectionExpression([int]$Low, [int]$High) {
    if ($Low -gt $High) { return '1' }
    $mid = [int][math]::Floor(($Low + $High) / 2)
    $left = New-SelectionExpression $Low ($mid - 1)
    $right = New-SelectionExpression ($mid + 1) $High
    # Balanced tree avoids deep parser recursion and scans only O(log N)
    # interval boundaries for each frame.
    return "if(lt(n,$($episodes[$mid].first_frame)),$left,if(lte(n,$($episodes[$mid].last_frame)),0,$right))"
}
function Quote-NativeArgument([string]$Value) {
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

$filterPath = "$outputPath.filter.txt"
$logPath = "$outputPath.log"
$progressPath = "$outputPath.progress"
$selectExpression = New-SelectionExpression 0 ($episodes.Count - 1)
# The input was checked to have one frame per 20 ms throughout. Keeping its
# original PTS and rounding up fills ONLY the selected gaps with the last good
# frame; it does not shorten the timeline or resample/cut the audio.
$filter = "select='$selectExpression',fps=50:round=up:eof_action=pass"
Set-Content -LiteralPath $filterPath -Value $filter -Encoding ASCII
$arguments = @(
    '-hide_banner', '-nostdin', '-nostats', '-n',
    '-progress', $progressPath, '-copyts', '-i', $inputItem.FullName,
    '-map', '0:v:0', '-map', '0:a?', '-map_metadata', '0', '-map_chapters', '0',
    '-filter_script:v', $filterPath,
    '-c:v', 'libx264', '-preset', $Preset, '-crf', '18', '-pix_fmt', 'yuv420p',
    '-fps_mode', 'passthrough', '-enc_time_base:v', '1:50',
    '-c:a', 'copy', '-avoid_negative_ts', 'disabled', $outputPath
)
[pscustomobject]@{
    Source = $inputItem.FullName; Output = $outputPath; Episodes = $episodes.Count
    ReplacedFrames = $replacedFrames; FrameCount = $source.FrameCount
    Method = 'Hold previous valid image at detected flashes; original audio stream copied'
    Arguments = $arguments
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$outputPath.repair.json" -Encoding UTF8
if ($PrepareOnly) { Write-Output "Prepared: $filterPath"; return }

$startInfo = New-Object System.Diagnostics.ProcessStartInfo
$startInfo.FileName = (Get-Command ffmpeg -ErrorAction Stop).Source
$startInfo.Arguments = ($arguments | ForEach-Object { Quote-NativeArgument $_ }) -join ' '
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardError = $true
$process = New-Object System.Diagnostics.Process
$process.StartInfo = $startInfo
$null = $process.Start()
$errorRead = $process.StandardError.ReadToEndAsync()
while (-not $process.WaitForExit(30000)) {
    if (Test-Path -LiteralPath $progressPath) {
        $status = Get-Content -LiteralPath $progressPath -Tail 12 | Where-Object { $_ -match '^(out_time|speed)=' }
        Write-Output ($status -join '; ')
    }
}
$errors = $errorRead.GetAwaiter().GetResult()
Set-Content -LiteralPath $logPath -Value $errors -Encoding UTF8
$exitCode = $process.ExitCode
$process.Dispose()
if ($exitCode -ne 0) { throw "Repair failed with FFmpeg exit code $exitCode. See $logPath" }
Write-Output "Created: $outputPath"
Write-Output "Episodes: $($episodes.Count); replaced frames: $replacedFrames. Validate before delivery."
