[CmdletBinding()]
param(
    [string]$OutputDirectory = '.\diagnostics',
    [ValidateRange(10, 120)]
    [int]$DurationSeconds = 60,
    [string]$VideoDevice = 'Roxio Video Capture USB',
    [int]$CrossbarPin = 2
)

# Video-only diagnostic: retain each received picture, bypass temporal filters
# and H.264. Assign sequential 25 fps timestamps to isolate picture content
# from arrival timing. This is not a production capture or an A/V sync test.
$ErrorActionPreference = 'Stop'
$ffmpeg = (Get-Command ffmpeg -ErrorAction Stop).Source
$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
$stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$outputFile = Join-Path $OutputDirectory "dazzle-diagnostic-$stamp.mkv"
$logFile = [IO.Path]::ChangeExtension($outputFile, '.log')
$captureArguments = @(
    '-hide_banner', '-n', '-nostats',
    '-f', 'dshow', '-thread_queue_size', '2048', '-rtbufsize', '512M',
    '-crossbar_video_input_pin_number', "$CrossbarPin",
    '-video_size', '720x576', '-framerate', '25',
    '-use_video_device_timestamps', 'false',
    '-i', "video=$VideoDevice",
    '-t', "$DurationSeconds", '-map', '0:v:0', '-an',
    '-vf', 'setpts=N/(25*TB)',
    '-c:v', 'ffv1', '-level', '3', '-pix_fmt', 'yuv422p',
    '-fps_mode', 'passthrough', '-enc_time_base:v', '1:25',
    $outputFile
)
Write-Host 'Diagnostic only: video without audio, original interlaced pictures, sequential 25 fps timestamps.'
Write-Host 'Automatic stop after the selected video duration; press Q to finish early.'
Write-Host "Output: $outputFile"
'Diagnostic: FFV1, no audio, no deinterlacing/scaling; setpts=N/(25*TB); wallclock input.' |
    Set-Content -LiteralPath $logFile
# Windows PowerShell represents native stderr as ErrorRecord; do not abort on
# FFmpeg's ordinary progress/diagnostic output. Check its exit code instead.
$ErrorActionPreference = 'Continue'
& $ffmpeg @captureArguments 2>&1 | ForEach-Object {
    $message = $_.ToString()
    Add-Content -LiteralPath $logFile -Value $message
    Write-Host $message
}
$captureExitCode = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
if ($captureExitCode -ne 0) {
    throw "FFmpeg failed with exit code $captureExitCode. See $logFile"
}
Write-Host "Diagnostic completed: $outputFile"
