[CmdletBinding()]
param(
    [string]$OutputDirectory = "F:\Hi8",

    [AllowEmptyString()]
    [string]$LogDirectory = "",

    [AllowEmptyString()]
    [string]$IndexFile = "",

    [Alias("Comment")]
    [AllowEmptyString()]
    [string]$TapeLabel = "",

    [Alias("IndexComment")]
    [AllowEmptyString()]
    [string]$ContentDescription = "",

    [TimeSpan]$MaxDuration = ([TimeSpan]::FromHours(2)),

    [TimeSpan]$NoSignalDuration = ([TimeSpan]::FromSeconds(45)),

    [bool]$RequireSilence = $false,

    [bool]$NotifyOnCompletion = $true,

    [ValidateRange(1, 10)]
    [int]$NotificationRepeatCount = 2,

    [bool]$ShutdownOnCompletion = $false,

    [double]$SilenceThresholdDb = -45,

    [string]$VideoDevice = "Roxio Video Capture USB",

    # Exact DirectShow name exposed by the tested Italian Dazzle driver.
    [string]$AudioDevice = "Linea (Dazzle Video Capture USB Audio Device)",

    [int]$CrossbarPin = 2,

    [ValidateRange(0, 51)]
    [int]$Crf = 22,

    [ValidateSet("ultrafast", "superfast", "veryfast", "faster", "fast", "medium", "slow", "slower", "veryslow")]
    [string]$Preset = "medium"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-CommandAvailable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Convert-ToFfmpegTime {
    param(
        [Parameter(Mandatory = $true)]
        [TimeSpan]$Value
    )

    return "{0:00}:{1:00}:{2:00}.{3:000}" -f `
        [math]::Floor($Value.TotalHours), `
        $Value.Minutes, `
        $Value.Seconds, `
        $Value.Milliseconds
}

function Format-ByteSize {
    param(
        [Parameter(Mandatory = $true)]
        [Int64]$Bytes
    )

    if ($Bytes -ge 1GB) {
        return "{0:N2} GB" -f ($Bytes / 1GB)
    }

    if ($Bytes -ge 1MB) {
        return "{0:N1} MB" -f ($Bytes / 1MB)
    }

    if ($Bytes -ge 1KB) {
        return "{0:N0} KB" -f ($Bytes / 1KB)
    }

    return "$Bytes B"
}

function Quote-ProcessArgument {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    # Apply Windows command-line quoting rules.
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'

    return '"' + $escaped + '"'
}

function Invoke-CompletionAlert {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $true)]
        [bool]$Enabled,

        [Parameter(Mandatory = $true)]
        [int]$RepeatCount
    )

    if (-not $Enabled) {
        return
    }

    Write-Host "Audible alert: $Message"

    for ($index = 0; $index -lt $RepeatCount; $index++) {
        try {
            # Uses the Windows system audio output, so the alert remains audible
            # even when the PowerShell window is not in the foreground.
            [Console]::Beep(1100, 350)
        }
        catch {
            [System.Media.SystemSounds]::Exclamation.Play()
            Start-Sleep -Milliseconds 350
        }

        if ($index -lt ($RepeatCount - 1)) {
            Start-Sleep -Milliseconds 200
        }
    }
}

function Get-TapeLabelSuffix {
    param(
        [AllowEmptyString()]
        [string]$Value
    )

    $trimmedValue = $Value.Trim()

    if ([string]::IsNullOrWhiteSpace($trimmedValue)) {
        return ""
    }

    if ($trimmedValue.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
        throw "TapeLabel contains characters that are not valid in a Windows file name."
    }

    return " - $trimmedValue"
}

function Add-IndexEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IndexFile,

        [Parameter(Mandatory = $true)]
        [string]$FileBaseName,

        [AllowEmptyString()]
        [string]$Description
    )

    $trimmedDescription = $Description.Trim()

    if ($trimmedDescription -match '[\r\n\t]') {
        throw "ContentDescription cannot contain tabs or line breaks."
    }

    $entry = $FileBaseName

    if (-not [string]::IsNullOrWhiteSpace($trimmedDescription)) {
        $entry += "`t$trimmedDescription"
    }

    # An index created or edited by another program may not end in a newline.
    # Without one, Add-Content would merge this entry with the previous entry.
    if ((Test-Path -LiteralPath $IndexFile) -and ((Get-Item -LiteralPath $IndexFile).Length -gt 0)) {
        $lastByte = [IO.File]::ReadAllBytes($IndexFile)[-1]
        if ($lastByte -ne 10) {
            Add-Content -LiteralPath $IndexFile -Value "" -Encoding UTF8
        }
    }

    Add-Content -LiteralPath $IndexFile -Value $entry -Encoding UTF8
    return $entry
}

function Request-ComputerShutdown {
    Write-Host "Computer shutdown scheduled in 30 seconds. To cancel: shutdown /a"

    $shutdownProcess = Start-Process `
        -FilePath (Join-Path $env:SystemRoot "System32\shutdown.exe") `
        -ArgumentList @(
            "/s"
            "/t"
            "30"
            "/f"
            "/c"
            "Hi8 capture completed"
        ) `
        -Wait `
        -PassThru

    if ($shutdownProcess.ExitCode -ne 0) {
        throw "Unable to schedule computer shutdown (shutdown.exe returned $($shutdownProcess.ExitCode))."
    }
}

if (-not (Test-CommandAvailable -Name "ffmpeg")) {
    throw "ffmpeg is not available on PATH."
}

if ($MaxDuration -le [TimeSpan]::Zero) {
    throw "MaxDuration must be greater than zero."
}

if ($NoSignalDuration -lt [TimeSpan]::FromSeconds(20)) {
    throw "NoSignalDuration must be at least 20 seconds to prevent accidental stops."
}

if ($SilenceThresholdDb -gt 0) {
    throw "SilenceThresholdDb must be negative, for example -45."
}

if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}

$outputDirectoryItem = Get-Item -LiteralPath $OutputDirectory

if (-not $outputDirectoryItem.PSIsContainer) {
    throw "Output path is not a directory: $OutputDirectory"
}

if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
    $LogDirectory = $outputDirectoryItem.FullName
}

if (-not (Test-Path -LiteralPath $LogDirectory)) {
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
}

$logDirectoryItem = Get-Item -LiteralPath $LogDirectory

if (-not $logDirectoryItem.PSIsContainer) {
    throw "Log path is not a directory: $LogDirectory"
}

if ([string]::IsNullOrWhiteSpace($IndexFile)) {
    $IndexFile = Join-Path $outputDirectoryItem.FullName "index.txt"
}
else {
    $IndexFile = [IO.Path]::GetFullPath($IndexFile)
    $indexDirectory = Split-Path -Path $IndexFile -Parent

    if (-not (Test-Path -LiteralPath $indexDirectory)) {
        New-Item -ItemType Directory -Path $indexDirectory -Force | Out-Null
    }

    if (-not (Get-Item -LiteralPath $indexDirectory).PSIsContainer) {
        throw "Index-file parent path is not a directory: $indexDirectory"
    }
}

$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$tapeLabelSuffix = Get-TapeLabelSuffix -Value $TapeLabel
$outputFile = Join-Path $outputDirectoryItem.FullName "hi8-capture-$timestamp$tapeLabelSuffix.mkv"
$logFile = Join-Path $logDirectoryItem.FullName "hi8-capture-$timestamp$tapeLabelSuffix.log"

$videoFilter = @(
    "yadif=1:-1:0"
    "scale=768:576:flags=lanczos"
    "setsar=1"
) -join ","

# blackdetect reports an interval only after black ends, so it cannot stop a
# source that remains black. A separate branch analyses one frame per second
# without slowing down the recorded video.
$detectionFilter = @(
    "fps=1"
    "blackframe=98:32"
    "freezedetect=n=0.003:d=2"
) -join ","

$filterComplex = "[0:v]split=2[record][detect];[record]$videoFilter[video];[detect]$detectionFilter,nullsink"

$thresholdText = $SilenceThresholdDb.ToString(
    [Globalization.CultureInfo]::InvariantCulture
)

$audioFilter = @(
    "silencedetect=n=${thresholdText}dB:d=2"
    "aresample=async=1:first_pts=0"
) -join ","

$ffmpegArguments = @(
    "-hide_banner"
    "-loglevel"
    "info"
    "-nostats"
    "-progress"
    "pipe:1"
    "-f"
    "dshow"
    "-thread_queue_size"
    "2048"
    "-rtbufsize"
    "512M"
    "-crossbar_video_input_pin_number"
    "$CrossbarPin"
    "-video_size"
    "720x576"
    "-framerate"
    "25"
    "-i"
    "video=$VideoDevice`:audio=$AudioDevice"
    "-t"
    (Convert-ToFfmpegTime -Value $MaxDuration)
    "-filter_complex"
    $filterComplex
    "-map"
    "[video]"
    "-map"
    "0:a?"
    "-c:v"
    "libx264"
    "-preset"
    $Preset
    "-crf"
    "$Crf"
    "-pix_fmt"
    "yuv420p"
    "-c:a"
    "aac"
    "-b:a"
    "128k"
    "-ar"
    "44100"
    "-ac"
    "2"
    "-af"
    $audioFilter
    "-fps_mode"
    "cfr"
    $outputFile
)

$startInfo = New-Object System.Diagnostics.ProcessStartInfo
$startInfo.FileName = (Get-Command ffmpeg).Source
$startInfo.Arguments = (
    $ffmpegArguments |
        ForEach-Object { Quote-ProcessArgument -Value ([string]$_) }
) -join " "
$startInfo.UseShellExecute = $false
$startInfo.RedirectStandardInput = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$startInfo.CreateNoWindow = $true

$process = New-Object System.Diagnostics.Process
$process.StartInfo = $startInfo

Write-Host ""
Write-Host "Hi8 Capture"
Write-Host "Video: $VideoDevice"
Write-Host "Audio: $AudioDevice"
Write-Host "Output: $outputFile"
Write-Host "Log: $logFile"
if ($tapeLabelSuffix) {
    Write-Host "Tape label: $TapeLabel"
}
Write-Host "Maximum duration: $MaxDuration"
Write-Host "Automatic stop after: $NoSignalDuration"
Write-Host "Also require silence: $RequireSilence"
Write-Host "Shut down computer on completion: $ShutdownOnCompletion"
Write-Host ""
Write-Host "Stop condition:"
Write-Host "black screen or frozen image for the configured threshold"
if ($RequireSilence) {
    Write-Host "and silent audio for the same threshold."
}
Write-Host ""
Write-Host "Press Q to stop the capture cleanly."
Write-Host ""

# Create the log before starting ffmpeg. If the device immediately rejects the
# connection, the process may exit before the monitoring loop reads stderr;
# the log must still retain the startup error.
New-Item -ItemType File -Path $logFile -Force | Out-Null

if (-not $process.Start()) {
    throw "Unable to start ffmpeg."
}

$stdoutTask = $process.StandardOutput.ReadLineAsync()
$stderrTask = $process.StandardError.ReadLineAsync()

$captureStartedAt = [DateTime]::UtcNow
$encodedSeconds = 0.0
$encodedFrames = [Int64]0
$encodingFps = 0.0
$outputBytes = [Int64]0
$outputBitrate = "N/A"
$encodingSpeed = "N/A"
$duplicatedFrames = [Int64]0
$droppedFrames = [Int64]0
$deviceWarningCount = 0
$blackStart = $null
$blackLastSeenAt = $null
$freezeStart = $null
$silenceStart = $null
$stopReason = $null
$stopSent = $false
$lastConsoleUpdate = [DateTime]::MinValue

try {
    while (-not $process.HasExited) {
        if ($stdoutTask.IsCompleted) {
            $line = $stdoutTask.Result

            if ($null -ne $line) {
                if ($line -match '^out_time=(?<value>\d{2,}:\d{2}:\d{2}(?:\.\d+)?)$') {
                    $parsed = [TimeSpan]::Zero

                    if ([TimeSpan]::TryParse($Matches.value, [ref]$parsed)) {
                        $encodedSeconds = $parsed.TotalSeconds
                    }
                }

                if ($line -match '^frame=(?<value>\d+)$') {
                    $encodedFrames = [Int64]$Matches.value
                }

                if ($line -match '^fps=(?<value>\d+(?:\.\d+)?)$') {
                    $encodingFps = [double]::Parse(
                        $Matches.value,
                        [Globalization.CultureInfo]::InvariantCulture
                    )
                }

                if ($line -match '^total_size=(?<value>\d+)$') {
                    $outputBytes = [Int64]$Matches.value
                }

                if ($line -match '^bitrate=(?<value>.+)$') {
                    $outputBitrate = $Matches.value.Trim()
                }

                if ($line -match '^speed=(?<value>.+)$') {
                    $encodingSpeed = $Matches.value.Trim()
                }

                if ($line -match '^dup_frames=(?<value>\d+)$') {
                    $duplicatedFrames = [Int64]$Matches.value
                }

                if ($line -match '^drop_frames=(?<value>\d+)$') {
                    $droppedFrames = [Int64]$Matches.value
                }

                $stdoutTask = $process.StandardOutput.ReadLineAsync()
            }
        }

        if ($stderrTask.IsCompleted) {
            $line = $stderrTask.Result

            if ($null -ne $line) {
                Add-Content -LiteralPath $logFile -Value $line

                if ($line -match 'pblack:(?<value>\d+)') {
                    $now = [DateTime]::UtcNow

                    if ($null -eq $blackStart) {
                        $blackStart = $now
                    }

                    $blackLastSeenAt = $now
                }

                if ($line -match 'freeze_start:\s*(?<value>\d+(?:\.\d+)?)') {
                    $freezeStart = [DateTime]::UtcNow
                }

                if ($line -match 'freeze_end:') {
                    $freezeStart = $null
                }

                if ($line -match 'silence_start:\s*(?<value>\d+(?:\.\d+)?)') {
                    $silenceStart = [DateTime]::UtcNow
                }

                if ($line -match 'silence_end:') {
                    $silenceStart = $null
                }

                if ($line -match '(?i)\b(error|fatal)\b') {
                    Write-Warning $line
                }

                # DirectShow has no structured hardware-drop counter. Keep
                # source/buffer warnings separate from FFmpeg sync drops.
                if ($line -match '(?i)(real-time buffer.*too full|buffer.*too full|dropp(?:ed|ing).*frames?)') {
                    $deviceWarningCount++
                }

                $stderrTask = $process.StandardError.ReadLineAsync()
            }
        }

        $manualStop = $false

        try {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)

                if ($key.Key -eq [ConsoleKey]::Q) {
                    $manualStop = $true
                }
            }
        }
        catch {
            # KeyAvailable may be unavailable in some remote or hosted consoles.
        }

        if ($manualStop -and -not $stopSent) {
            $stopReason = "manual stop"
        }

        $now = [DateTime]::UtcNow
        $currentSeconds = ($now - $captureStartedAt).TotalSeconds

        # blackframe writes one line per second only while the image is black.
        # If no more lines arrive, the video is no longer black.
        if (
            $null -ne $blackLastSeenAt -and
            ($now - $blackLastSeenAt).TotalSeconds -gt 2.5
        ) {
            $blackStart = $null
            $blackLastSeenAt = $null
        }

        $blackElapsed = if ($null -eq $blackStart) {
            0.0
        }
        else {
            ($now - $blackStart).TotalSeconds
        }

        $freezeElapsed = if ($null -eq $freezeStart) {
            0.0
        }
        else {
            ($now - $freezeStart).TotalSeconds
        }

        $silenceElapsed = if ($null -eq $silenceStart) {
            0.0
        }
        else {
            ($now - $silenceStart).TotalSeconds
        }

        $videoNoSignal = (
            $blackElapsed -ge $NoSignalDuration.TotalSeconds -or
            $freezeElapsed -ge $NoSignalDuration.TotalSeconds
        )

        $audioNoSignal = (
            -not $RequireSilence -or
            $silenceElapsed -ge $NoSignalDuration.TotalSeconds
        )

        if (-not $stopReason -and $currentSeconds -ge $MaxDuration.TotalSeconds) {
            $stopReason = "maximum duration reached"
        }

        if (
            -not $stopReason -and
            $videoNoSignal -and
            $audioNoSignal
        ) {
            if ($blackElapsed -ge $NoSignalDuration.TotalSeconds) {
                $stopReason = "continuous black screen"
            }
            else {
                $stopReason = "continuous frozen image"
            }

            if ($RequireSilence) {
                $stopReason += " with silent audio"
            }
        }

        if ($stopReason -and -not $stopSent) {
            Write-Host ""
            Write-Host "Stop requested: $stopReason"
            $process.StandardInput.WriteLine("q")
            $process.StandardInput.Flush()
            $stopSent = $true
        }

        if (((Get-Date) - $lastConsoleUpdate).TotalSeconds -ge 1) {
            # Wall time advances independently of FFmpeg's periodic progress
            # report. Keep it first so the operator sees the real capture time
            # immediately; "Encoded" may legitimately trail by a few seconds.
            $elapsed = [TimeSpan]::FromSeconds($currentSeconds)

            Write-Progress `
                -Activity "Hi8 Capture" `
                -Status (
                    "Wall {0} | Encoded {1} | {2:N0} frames | Encode {3:N1} fps | Speed {4} | Bitrate {5} | File {6} | Dup {7} | Drop {8} | Device warnings {9} | Black {10:N0}s | Freeze {11:N0}s | Silence {12:N0}s" -f `
                    $elapsed.ToString("hh\:mm\:ss"), `
                    ([TimeSpan]::FromSeconds($encodedSeconds)).ToString("hh\:mm\:ss"), `
                    $encodedFrames, `
                    $encodingFps, `
                    $encodingSpeed, `
                    $outputBitrate, `
                    (Format-ByteSize -Bytes $outputBytes), `
                    $duplicatedFrames, `
                    $droppedFrames, `
                    $deviceWarningCount, `
                    $blackElapsed, `
                    $freezeElapsed, `
                    $silenceElapsed
                ) `
                -PercentComplete (
                    [math]::Min(
                        100,
                        ($currentSeconds / $MaxDuration.TotalSeconds) * 100
                    )
                )

            $lastConsoleUpdate = Get-Date
        }

        Start-Sleep -Milliseconds 100
    }

    $process.WaitForExit()
}
finally {
    Write-Progress -Activity "Hi8 Capture" -Completed

    if (-not $process.HasExited) {
        try {
            $process.StandardInput.WriteLine("q")
            $process.StandardInput.Flush()

            if (-not $process.WaitForExit(10000)) {
                Write-Warning "ffmpeg did not exit within 10 seconds."
            }
        }
        catch {
            Write-Warning "Unable to request a clean ffmpeg shutdown."
        }
    }
}

# The process can exit before the first monitoring-loop iteration. Await the
# final asynchronous read and drain stderr so that a DirectShow startup error
# (for example, a device already in use) is not lost.
if (-not $stderrTask.IsCompleted) {
    $stderrTask.Wait()
}

$pendingErrorLine = $stderrTask.GetAwaiter().GetResult()

if ($null -ne $pendingErrorLine) {
    Add-Content -LiteralPath $logFile -Value $pendingErrorLine
}

while (($remainingErrorLine = $process.StandardError.ReadLine()) -ne $null) {
    Add-Content -LiteralPath $logFile -Value $remainingErrorLine
}

$exitCode = $process.ExitCode
$process.Dispose()

if ($exitCode -ne 0) {
    Invoke-CompletionAlert `
        -Message "Capture ended with an error" `
        -Enabled $NotifyOnCompletion `
        -RepeatCount $NotificationRepeatCount

    throw "ffmpeg exited with code $exitCode. Check the log: $logFile"
}

Write-Host ""
Write-Host "Capture completed:"
Write-Host $outputFile

if ($stopReason) {
    Write-Host "Stop reason: $stopReason"
}

$indexEntry = Add-IndexEntry `
    -IndexFile $indexFile `
    -FileBaseName ([IO.Path]::GetFileNameWithoutExtension($outputFile)) `
    -Description $ContentDescription

Write-Host "Index updated: $indexFile"
Write-Host "Index entry: $indexEntry"

Invoke-CompletionAlert `
    -Message "Capture completed" `
    -Enabled $NotifyOnCompletion `
    -RepeatCount $NotificationRepeatCount

if ($ShutdownOnCompletion) {
    Request-ComputerShutdown
}
