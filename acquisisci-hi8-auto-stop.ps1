[CmdletBinding()]
param(
    [string]$OutputDirectory = "F:\Hi8",

    [TimeSpan]$MaxDuration = ([TimeSpan]::FromMinutes(90)),

    [TimeSpan]$NoSignalDuration = ([TimeSpan]::FromSeconds(45)),

    [bool]$RequireSilence = $false,

    [bool]$NotifyOnCompletion = $true,

    [ValidateRange(1, 10)]
    [int]$NotificationRepeatCount = 3,

    [double]$SilenceThresholdDb = -45,

    [string]$VideoDevice = "Roxio Video Capture USB",

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

    Write-Host "Avviso sonoro: $Message"

    for ($index = 0; $index -lt $RepeatCount; $index++) {
        try {
            # Su Windows usa l'uscita audio di sistema: è udibile anche se la
            # finestra PowerShell non è in primo piano.
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

if (-not (Test-CommandAvailable -Name "ffmpeg")) {
    throw "ffmpeg non è disponibile nel PATH."
}

if ($MaxDuration -le [TimeSpan]::Zero) {
    throw "MaxDuration deve essere maggiore di zero."
}

if ($NoSignalDuration -lt [TimeSpan]::FromSeconds(20)) {
    throw "NoSignalDuration deve essere di almeno 20 secondi per evitare arresti accidentali."
}

if ($SilenceThresholdDb -gt 0) {
    throw "SilenceThresholdDb deve essere negativo, per esempio -45."
}

if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}

$outputDirectoryItem = Get-Item -LiteralPath $OutputDirectory

if (-not $outputDirectoryItem.PSIsContainer) {
    throw "Il percorso di output non è una cartella: $OutputDirectory"
}

$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$outputFile = Join-Path $outputDirectoryItem.FullName "acquisizione-hi8-$timestamp.mkv"
$logFile = Join-Path $outputDirectoryItem.FullName "acquisizione-hi8-$timestamp.log"

$videoFilter = @(
    "yadif=1:-1:0"
    "scale=768:576:flags=lanczos"
    "setsar=1"
) -join ","

# blackdetect annuncia un intervallo solo quando il nero termina: non può
# quindi arrestare una sorgente che resta nera. Analizziamo un frame al
# secondo su un ramo separato, senza rallentare il video registrato.
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
Write-Host "Acquisizione Hi8"
Write-Host "Video: $VideoDevice"
Write-Host "Audio: $AudioDevice"
Write-Host "Output: $outputFile"
Write-Host "Log: $logFile"
Write-Host "Durata massima: $MaxDuration"
Write-Host "Arresto automatico dopo: $NoSignalDuration"
Write-Host "Richiede anche silenzio: $RequireSilence"
Write-Host ""
Write-Host "Condizione di arresto:"
Write-Host "schermo nero oppure immagine congelata per la soglia impostata"
if ($RequireSilence) {
    Write-Host "e contemporaneamente audio silenzioso per la stessa soglia."
}
Write-Host ""
Write-Host "Premi Q per interrompere correttamente l'acquisizione."
Write-Host ""

# Crea il log prima di avviare ffmpeg. Se il dispositivo rifiuta subito la
# connessione, il processo può terminare prima che il ciclo di monitoraggio
# legga stderr; in quel caso il log deve comunque conservare l'errore.
New-Item -ItemType File -Path $logFile -Force | Out-Null

if (-not $process.Start()) {
    throw "Impossibile avviare ffmpeg."
}

$stdoutTask = $process.StandardOutput.ReadLineAsync()
$stderrTask = $process.StandardError.ReadLineAsync()

$captureStartedAt = [DateTime]::UtcNow
$encodedSeconds = 0.0
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
            $stopReason = "interruzione manuale"
        }

        $now = [DateTime]::UtcNow
        $currentSeconds = ($now - $captureStartedAt).TotalSeconds

        # blackframe emette una riga ogni secondo solo durante il nero.
        # Se non arriva più una riga, il video non è più nero.
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
            $stopReason = "durata massima raggiunta"
        }

        if (
            -not $stopReason -and
            $videoNoSignal -and
            $audioNoSignal
        ) {
            if ($blackElapsed -ge $NoSignalDuration.TotalSeconds) {
                $stopReason = "schermo nero continuo"
            }
            else {
                $stopReason = "immagine congelata continua"
            }

            if ($RequireSilence) {
                $stopReason += " con audio silenzioso"
            }
        }

        if ($stopReason -and -not $stopSent) {
            Write-Host ""
            Write-Host "Arresto richiesto: $stopReason"
            $process.StandardInput.WriteLine("q")
            $process.StandardInput.Flush()
            $stopSent = $true
        }

        if (((Get-Date) - $lastConsoleUpdate).TotalSeconds -ge 1) {
            $elapsed = [TimeSpan]::FromSeconds($currentSeconds)

            Write-Progress `
                -Activity "Acquisizione Hi8" `
                -Status (
                    "Tempo reale {0} | Nero {1:N0}s | Freeze {2:N0}s | Silenzio {3:N0}s" -f `
                    $elapsed.ToString("hh\:mm\:ss"), `
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
    Write-Progress -Activity "Acquisizione Hi8" -Completed

    if (-not $process.HasExited) {
        try {
            $process.StandardInput.WriteLine("q")
            $process.StandardInput.Flush()

            if (-not $process.WaitForExit(10000)) {
                Write-Warning "ffmpeg non si è chiuso entro 10 secondi."
            }
        }
        catch {
            Write-Warning "Impossibile richiedere la chiusura ordinata di ffmpeg."
        }
    }
}

# Il processo può terminare prima del primo giro del ciclo. Attendi l'ultima
# lettura asincrona e svuota stderr per non perdere l'errore di avvio di
# DirectShow (per esempio, dispositivo gia' in uso).
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
        -Message "Acquisizione terminata con errore" `
        -Enabled $NotifyOnCompletion `
        -RepeatCount $NotificationRepeatCount

    throw "ffmpeg è terminato con codice $exitCode. Controlla il log: $logFile"
}

Write-Host ""
Write-Host "Acquisizione completata:"
Write-Host $outputFile

if ($stopReason) {
    Write-Host "Motivo arresto: $stopReason"
}

Invoke-CompletionAlert `
    -Message "Acquisizione completata" `
    -Enabled $NotifyOnCompletion `
    -RepeatCount $NotificationRepeatCount
