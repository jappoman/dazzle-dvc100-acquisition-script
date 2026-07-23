[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$DriverRoot = (Join-Path $PSScriptRoot 'drivers'),
    [switch]$CheckOnly,
    [switch]$Detailed,
    [Alias('RepairVideo')][switch]$Repair,
    [switch]$SkipBootstrap,
    [switch]$VideoOnly,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$SkipPrompt,
    [ValidateRange(10, 3600)][int]$TimeoutSeconds = 120,
    [string]$LogPath = (Join-Path $PSScriptRoot 'dazzle-driver-install.log')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The script never edits INF files, the registry, signature policy, or device enablement state.
$VideoId = 'USB\VID_1B80&PID_E60A&MI_00'
$AudioId = 'USB\VID_1B80&PID_E60A&MI_01'
$ExpectedVideoProvider = 'Corel Corporation'
$ExpectedVideoVersion = '5.2020.0406.1015'
$KnownBadProvider = 'Pinnacle Systems'
$KnownBadVersion = '5.2012.416.2725'
$runRoot = Join-Path $env:TEMP ('dazzle-dvc100-' + [guid]::NewGuid().ToString('N'))
$script:Actions = New-Object System.Collections.Generic.List[string]
$script:DetectedDsVideo = $null
$script:DetectedDsAudio = $null
$script:FfmpegAvailable = $false
$script:RollbackPath = $null
$script:ProtectedAudioInf = $null

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR','DRYRUN')][string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ssK'),$Level,$Message
    if ($Detailed -or $Level -eq 'ERROR') { Write-Host $line }
    if (-not $WhatIfPreference) { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 }
}

function Write-Status([string]$Message) {
    Write-Host $Message
    Write-Log $Message
}

function Show-SimpleSummary([object]$Video, [object]$Audio, [string]$VideoState, [string]$AudioState) {
    Write-Host ''
    Write-Host '=== Risultato Dazzle ==='
    if ($VideoState -eq 'Correct') { Write-Host 'Video: OK - il driver EMBDA corretto e gia attivo.' }
    elseif ($VideoState -eq 'LegacyIncompatible') { Write-Host 'Video: DA RIPARARE - e attivo il vecchio driver Pinnacle non funzionante.' }
    elseif ($VideoState -eq 'Missing') { Write-Host 'Video: NON RILEVATO - collega la Dazzle e riprova.' }
    else { Write-Host "Video: ATTENZIONE - stato $VideoState. Nessuna modifica automatica." }
    if ($AudioState -eq 'Working') { Write-Host 'Audio: OK.' }
    elseif ($AudioState -eq 'KnownStutteringDriver') { Write-Host 'Audio: PROBLEMA NON RISOLVIBILE AUTOMATICAMENTE - il driver Pinnacle 2014 disponibile stuttera su questo PC.' }
    elseif ($AudioState -eq 'Missing') { Write-Host 'Audio: NON RILEVATO - il bootstrap sara necessario durante la riparazione.' }
    else { Write-Host "Audio: ATTENZIONE - stato $AudioState. L audio non verra rimosso." }
    if ($script:FfmpegAvailable) {
        $videoName = $(if ($script:DetectedDsVideo) { $script:DetectedDsVideo } else { 'non trovato' })
        $audioName = $(if ($script:DetectedDsAudio) { $script:DetectedDsAudio } else { 'non trovato' })
        Write-Host "DirectShow: video '$videoName'; audio '$audioName'."
    } else { Write-Host 'DirectShow: FFmpeg non è disponibile; verifica saltata.' }
    Write-Host 'Dettagli completi: dazzle-driver-install.log (oppure usa -Detailed).'
}

function Show-SimpleRepairPlan([object]$Video, [bool]$BootstrapNeeded) {
    Write-Host ''
    Write-Host '=== Piano di riparazione ==='
    if ($BootstrapNeeded) { Write-Host '1. Eseguire il bootstrap locale Pinnacle per ripristinare i prerequisiti audio.' } else { Write-Host '1. Bootstrap audio non necessario.' }
    Write-Host '2. Aggiungere il driver video EMBDA validato.'
    if ($Video -and $Video.InfName) { Write-Host "3. Solo se necessario e sicuro, rimuovere il vecchio driver video $($Video.InfName)." }
    Write-Host '4. Ricollegare la Dazzle e verificare video e audio.'
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-DazzleInterfaces {
    $entities = @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.DeviceID -like 'USB\VID_1B80&PID_E60A*' })
    $signed = @(Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceID -like 'USB\VID_1B80&PID_E60A*' })
    $ids = @(@($entities.DeviceID) + @($signed.DeviceID) | Where-Object { $_ } | Sort-Object -Unique)
    foreach ($id in $ids) {
        $entity = @($entities | Where-Object DeviceID -eq $id)
        $driver = @($signed | Where-Object DeviceID -eq $id)
        if ($entity.Count -gt 1 -or $driver.Count -gt 1) { throw "Ambiguous device data for $id." }
        $entity = $entity | Select-Object -First 1
        $driver = $driver | Select-Object -First 1
        $hardwareList = $(if ($entity) { @($entity.HardwareID | ForEach-Object { $_.ToUpperInvariant() }) } else { @() })
        [pscustomobject]@{
            DeviceId=$id; Status=$(if ($entity) { $entity.Status } else { 'NotPresent' })
            ProblemCode=$(if ($entity) { $entity.ConfigManagerErrorCode } else { $null })
            FriendlyName=$(if ($entity) { $entity.Name } elseif ($driver) { $driver.DeviceName } else { $null })
            DriverProviderName=$(if ($driver) { $driver.DriverProviderName } else { $null })
            DriverVersion=$(if ($driver) { $driver.DriverVersion } else { $null })
            DriverDate=$(if ($driver) { $driver.DriverDate } else { $null })
            InfName=$(if ($driver) { $driver.InfName } else { $null })
            Service=$(if ($entity) { $entity.Service } else { $null })
            ClassGuid=$(if ($entity) { $entity.ClassGuid } else { $null })
            HardwareIdList=$hardwareList; HardwareIds=$hardwareList -join '; '
            CompatibleIds=$(if ($entity) { @($entity.CompatibleID) -join '; ' } else { $null })
        }
    }
}

function Get-OneInterface([string]$Id) {
    $matches = @(Get-DazzleInterfaces | Where-Object { $_.DeviceId -like "*$Id*" -or $_.HardwareIdList -contains $Id })
    if ($matches.Count -gt 1) { throw "Ambiguous: more than one interface matches $Id." }
    return $matches | Select-Object -First 1
}

function Show-Interface([object]$Interface, [string]$Label) {
    if (-not $Interface) { Write-Log "${Label}: not present." 'WARN'; return }
    Write-Log ("{0}: Status={1}; ProblemCode={2}; FriendlyName={3}; DriverProviderName={4}; DriverVersion={5}; DriverDate={6}; InfName={7}; Service={8}; ClassGuid={9}; HardwareIds={10}; CompatibleIds={11}" -f $Label,$Interface.Status,$Interface.ProblemCode,$Interface.FriendlyName,$Interface.DriverProviderName,$Interface.DriverVersion,$Interface.DriverDate,$Interface.InfName,$Interface.Service,$Interface.ClassGuid,$Interface.HardwareIds,$Interface.CompatibleIds)
}

function Get-InfInfo([IO.FileInfo]$Inf) {
    $content = Get-Content -LiteralPath $Inf.FullName -Raw
    $ids = @([regex]::Matches($content, 'USB\\VID_[0-9A-F]{4}&PID_[0-9A-F]{4}(?:&MI_[0-9A-F]{2})?', [Text.RegularExpressions.RegexOptions]::IgnoreCase) | ForEach-Object { $_.Value.ToUpperInvariant() } | Sort-Object -Unique)
    [pscustomobject]@{ Path=$Inf.FullName; Name=$Inf.Name; HardwareIds=$ids; Provider=([regex]::Match($content, '(?im)^\s*Provider\s*=\s*(.+?)\s*$')).Groups[1].Value.Trim(); DriverVersion=([regex]::Match($content, '(?im)^\s*DriverVer\s*=\s*(.+?)\s*$')).Groups[1].Value.Trim() }
}

function Get-ValidatedVideoPackage {
    $zip = Join-Path $DriverRoot 'usb-2828x-1176289.zip'
    if (-not (Test-Path -LiteralPath $zip -PathType Leaf)) { throw "Required video archive not found: $zip" }
    $destination = Join-Path $runRoot 'video'
    New-Item -ItemType Directory -Path $destination -Force -WhatIf:$false | Out-Null
    Expand-Archive -LiteralPath $zip -DestinationPath $destination -Force
    $candidates = @(Get-ChildItem -LiteralPath $destination -Recurse -File -Filter '*.inf' | ForEach-Object { Get-InfInfo $_ } | Where-Object { $_.Name -ieq 'EMBDA_x86_x64.inf' -and $_.HardwareIds -contains $VideoId })
    if ($candidates.Count -ne 1) { throw "Expected exactly one EMBDA_x86_x64.inf declaring $VideoId; found $($candidates.Count)." }
    $package = $candidates[0]
    $catalog = @(@(Get-ChildItem -LiteralPath $destination -Recurse -File -Filter '*.cat') | Where-Object { $_.Name -ieq 'emWHQL.cat' })
    if ($catalog.Count -ne 1) { throw 'Expected exactly one emWHQL.cat in the EMBDA package.' }
    $catalogSignature = Get-AuthenticodeSignature -LiteralPath $catalog[0].FullName
    if ($catalogSignature.Status -ne 'Valid') { throw "EMBDA catalog signature is not valid: $($catalogSignature.Status)" }
    foreach ($file in @('emBDA64.sys','emOEM64.sys','merlinFW.rom')) { if (-not (Test-Path -LiteralPath (Join-Path $destination $file) -PathType Leaf)) { throw "Required EMBDA package file is missing: $file" } }
    Write-Log ("Validated replacement video INF: Path={0}; HardwareIds={1}; Provider={2}; DriverVer={3}; Catalog={4}; CatalogSignature={5}" -f $package.Path,($package.HardwareIds -join ', '),$package.Provider,$package.DriverVersion,$catalog[0].FullName,$catalogSignature.Status)
    return $package
}

function Get-MsiProperty([object]$Database, [string]$Name) {
    $view = $Database.OpenView("SELECT `Value` FROM `Property` WHERE `Property`='$Name'")
    [void]$view.Execute(); $record = $view.Fetch(); [void]$view.Close()
    if ($record) { return $record.StringData(1).Trim() }
    return $null
}

function Get-ValidatedBootstrapPackage {
    $zip = Join-Path $DriverRoot 'Dazzle Drivers.zip'
    if (-not (Test-Path -LiteralPath $zip -PathType Leaf)) { throw "Required bootstrap archive not found: $zip" }
    $destination = Join-Path $runRoot 'bootstrap'
    New-Item -ItemType Directory -Path $destination -Force -WhatIf:$false | Out-Null
    Expand-Archive -LiteralPath $zip -DestinationPath $destination -Force
    if (-not (Test-Path -LiteralPath (Join-Path $destination 'Data1.cab') -PathType Leaf)) { throw 'Bootstrap Data1.cab is missing.' }
    $msis = @(Get-ChildItem -LiteralPath $destination -File -Filter '*.msi')
    $exes = @(Get-ChildItem -LiteralPath $destination -File -Filter '*.exe')
    if ($msis.Count -ne 1 -or $exes.Count -ne 1) { throw "Bootstrap archive is ambiguous: MSI=$($msis.Count), EXE=$($exes.Count)." }
    $msiSignature = Get-AuthenticodeSignature -LiteralPath $msis[0].FullName
    $exeSignature = Get-AuthenticodeSignature -LiteralPath $exes[0].FullName
    if ($msiSignature.Status -ne 'Valid' -or $exeSignature.Status -ne 'Valid') { throw "Bootstrap signature validation failed. MSI=$($msiSignature.Status); EXE=$($exeSignature.Status)." }
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $database = $installer.OpenDatabase($msis[0].FullName,0)
    $manufacturer = Get-MsiProperty $database 'Manufacturer'
    $productName = Get-MsiProperty $database 'ProductName'
    $productVersion = Get-MsiProperty $database 'ProductVersion'
    $productCode = Get-MsiProperty $database 'ProductCode'
    $upgradeCode = Get-MsiProperty $database 'UpgradeCode'
    if ($manufacturer -notmatch '^(?i)(Pinnacle|Corel|Roxio)$') { throw "Unexpected MSI manufacturer: $manufacturer" }
    $view = $database.OpenView('SELECT `Component` FROM `MsiDriverPackages`')
    [void]$view.Execute(); $driverComponents=@(); while($record=$view.Fetch()) { $driverComponents += $record.StringData(1) }; [void]$view.Close()
    if (@($driverComponents | Sort-Object -Unique).Count -ne 2 -or $driverComponents -notcontains 'EMAUDIO_x86_x64_INF' -or $driverComponents -notcontains 'EMVIDEO_INF') { throw 'Unexpected DIFx driver package table in bootstrap MSI.' }
    $fileVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($exes[0].FullName).FileVersion
    Write-Log ("Bootstrap launcher: Path={0}; Signature={1}; Publisher={2}; Version={3}" -f $exes[0].FullName,$exeSignature.Status,$exeSignature.SignerCertificate.Subject,$fileVersion)
    Write-Log ("Bootstrap MSI: Path={0}; Signature={1}; Signer={2}; Manufacturer={3}; Product={4}; Version={5}; ProductCode={6}; UpgradeCode={7}; DIFxComponents={8}" -f $msis[0].FullName,$msiSignature.Status,$msiSignature.SignerCertificate.Subject,$manufacturer,$productName,$productVersion,$productCode,$upgradeCode,($driverComponents -join ', '))
    return [pscustomobject]@{ MsiPath=$msis[0].FullName; ExePath=$exes[0].FullName; ProductCode=$productCode; UpgradeCode=$upgradeCode; Manufacturer=$manufacturer; ProductName=$productName; ProductVersion=$productVersion; DriverComponents=$driverComponents }
}

function Get-VideoDriverState([object]$Video) {
    if (-not $Video -or $Video.Status -eq 'NotPresent') { return 'Missing' }
    if ($Video.Status -ne 'OK' -or $Video.ProblemCode -ne 0) { return 'Error' }
    if ($Video.Service -eq 'USB28xxBGA') {
        $service = Get-CimInstance Win32_SystemDriver -Filter "Name='USB28xxBGA'" -ErrorAction SilentlyContinue
        $driverPath = if ($service) { $service.PathName -replace '^"|"$','' } else { $null }
        if ($driverPath -and $driverPath -match '(?i)\\emBDA64\.sys$' -and (Test-Path -LiteralPath $driverPath -PathType Leaf)) {
            $signature = Get-AuthenticodeSignature -LiteralPath $driverPath
            if ($signature.Status -eq 'Valid') { return 'Correct' }
        }
    }
    if ($Video.DriverProviderName -eq $ExpectedVideoProvider -and $Video.DriverVersion -eq $ExpectedVideoVersion) { return 'Correct' }
    if ($Video.DriverProviderName -eq $KnownBadProvider -and $Video.DriverVersion -eq $KnownBadVersion -and $Video.Service -eq 'DCamUSBEMPIA') { return 'LegacyIncompatible' }
    return 'Unknown'
}

function Get-AudioDriverState([object]$Audio) {
    if (-not $Audio -or $Audio.Status -eq 'NotPresent') { return 'Missing' }
    if ($Audio.Status -ne 'OK' -or $Audio.ProblemCode -ne 0) { return 'Error' }
    if ($Audio.DriverProviderName -eq $KnownBadProvider -and $Audio.DriverVersion -eq $KnownBadVersion -and $Audio.Service -eq 'emAudio') { return 'KnownStutteringDriver' }
    return 'Working'
}

function Get-PackageUsers([string]$InfName) {
    @(Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.InfName -eq $InfName })
}

function Test-SafeVideoRemoval([object]$Video, [object]$Replacement, [bool]$ReplacementAdded) {
    if (-not $ReplacementAdded) { return $false }
    return Test-VideoRemovalIdentity -Video $Video -Replacement $Replacement
}

function Test-VideoRemovalIdentity([object]$Video, [object]$Replacement) {
    if (-not $Video -or -not $Replacement) { return $false }
    if ($Video.DeviceId -notlike "*$VideoId*" -or $Video.HardwareIdList -notcontains $VideoId) { return $false }
    if ([string]::IsNullOrWhiteSpace($Video.InfName) -or $Video.InfName -notmatch '^oem\d+\.inf$') { return $false }
    if ($Video.DriverProviderName -eq 'Microsoft') { return $false }
    if ($Replacement.HardwareIds -notcontains $VideoId -or $Replacement.Name -ine 'EMBDA_x86_x64.inf') { return $false }
    $users = @(Get-PackageUsers $Video.InfName)
    return $users.Count -eq 1 -and $users[0].DeviceID -eq $Video.DeviceId
}

function Write-RollbackReport([object]$Current, [object]$Replacement, [string[]]$Commands) {
    if ($DryRun -or $WhatIfPreference) { Write-Log 'Simulation: rollback report was not written because no system modification will run.' 'DRYRUN'; return }
    $directory = Split-Path -Parent $LogPath
    if ([string]::IsNullOrWhiteSpace($directory)) { $directory = $PSScriptRoot }
    $script:RollbackPath = Join-Path $directory ('dazzle-driver-rollback-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
    $report = [pscustomobject]@{
        Created=(Get-Date).ToString('o'); Warning='This report records prior state only. It does not promise automatic rollback after a Driver Store package is deleted.'
        InstanceId=$Current.DeviceId; InfName=$Current.InfName; Provider=$Current.DriverProviderName; DriverVersion=$Current.DriverVersion; Service=$Current.Service; ClassGuid=$Current.ClassGuid; HardwareIds=$Current.HardwareIdList
        NewInfPath=$Replacement.Path; PlannedCommands=$Commands; ExecutedCommands=@($script:Actions)
    }
    $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:RollbackPath -Encoding UTF8
    Write-Log "Rollback report written: $script:RollbackPath"
}

function Confirm-Explicit([string]$Question) {
    if ($DryRun -or $WhatIfPreference) { return $true }
    if ($SkipPrompt -and $Force) { return $true }
    return (Read-Host "$Question [y/N]") -match '^(?i)y(es)?$'
}

function Invoke-PnpUtilChange {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param([string[]]$Arguments, [string]$Target, [string]$Action)
    $command = 'pnputil.exe ' + (($Arguments | ForEach-Object { '"{0}"' -f $_ }) -join ' ')
    Write-Log "Planned command: $command"
    if ($DryRun) { Write-Log ("DryRun target: {0}; command: {1}" -f $Target,$command) 'DRYRUN'; $script:Actions.Add("Simulated: $command"); return $true }
    if (-not $PSCmdlet.ShouldProcess($Target,$Action)) { Write-Log "WhatIf or confirmation declined: $command" 'WARN'; return $false }
    $output = & pnputil.exe @Arguments 2>&1 | ForEach-Object { $_.ToString() }
    $output | ForEach-Object { Write-Log "pnputil: $_" }
    if ($LASTEXITCODE -ne 0) { throw "pnputil failed with exit code ${LASTEXITCODE}: $command" }
    $script:Actions.Add($command)
    return $true
}

function Invoke-BootstrapInstaller {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param([object]$Bootstrap)
    $command = '"{0}" (interactive)' -f $Bootstrap.ExePath
    Write-Log "Planned command: $command"
    if ($DryRun) { Write-Log "DryRun bootstrap command: $command" 'DRYRUN'; $script:Actions.Add("Simulated: $command"); return $true }
    if (-not $PSCmdlet.ShouldProcess($Bootstrap.ExePath,'Run validated Dazzle bootstrap installer interactively')) {
        if ($WhatIfPreference) { return $true }
        Write-Log 'Confirmation declined for bootstrap installer.' 'WARN'
        return $false
    }
    Write-Status 'Si aprira il programma di installazione Dazzle. Completa la procedura guidata e attendi la sua chiusura.'
    $process = Start-Process -FilePath $Bootstrap.ExePath -Wait -PassThru
    Write-Log "Bootstrap installer exit code: $($process.ExitCode)"
    if ($process.ExitCode -ne 0) { throw "Bootstrap installer failed with exit code $($process.ExitCode)." }
    $script:Actions.Add($command)
    return $true
}

function Wait-ForInterfaces {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do { Start-Sleep -Seconds 2; $video = Get-OneInterface $VideoId; $audio = Get-OneInterface $AudioId } while ((-not $video -or -not $audio) -and (Get-Date) -lt $deadline)
    [pscustomobject]@{ Video=$video; Audio=$audio }
}

function Get-DirectShowDevices {
    $ffmpeg = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
    if (-not $ffmpeg) { Write-Log 'ffmpeg.exe is not on PATH; DirectShow devices were not queried.' 'WARN'; return }
    $script:FfmpegAvailable = $true
    # FFmpeg returns a non-zero exit code after listing DirectShow devices; that is expected.
    $savedErrorActionPreference = $ErrorActionPreference
    $savedNativeErrorPreference = Get-Variable -Name PSNativeCommandUseErrorActionPreference -Scope Global -ErrorAction SilentlyContinue
    try {
        $ErrorActionPreference = 'Continue'
        if ($savedNativeErrorPreference) { $global:PSNativeCommandUseErrorActionPreference = $false }
        $output = @(& $ffmpeg.Source -list_devices true -f dshow -i dummy 2>&1 | ForEach-Object { $_.ToString() })
        $ffmpegExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedErrorActionPreference
        if ($savedNativeErrorPreference) { $global:PSNativeCommandUseErrorActionPreference = $savedNativeErrorPreference.Value }
    }
    Write-Log "ffmpeg DirectShow listing exit code: $ffmpegExitCode"
    $output | ForEach-Object { Write-Log "ffmpeg: $_" }
    $text = $output -join "`n"
    $video = [regex]::Match($text, '"(Roxio Video Capture USB|[^"]*Dazzle[^"]*(?:Video|Capture)[^"]*)"', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $audio = [regex]::Match($text, '"(Linea \(Dazzle Video Capture USB Audio Device\)|[^"]*Dazzle[^"]*Audio[^"]*)"', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($video.Success) { $script:DetectedDsVideo = $video.Groups[1].Value; Write-Log "Detected DirectShow video: $script:DetectedDsVideo" } else { Write-Log 'No Dazzle DirectShow video device detected.' 'WARN' }
    if ($audio.Success) { $script:DetectedDsAudio = $audio.Groups[1].Value; Write-Log "Detected DirectShow audio: $script:DetectedDsAudio" } else { Write-Log 'No Dazzle DirectShow audio device detected.' 'WARN' }
}

try {
    if (-not $WhatIfPreference) { New-Item -ItemType File -Path $LogPath -Force | Out-Null }
    Write-Log 'Dazzle safe diagnostic and repair started.'
    # Load CIM before entering the WhatIf flow to prevent module-initialization noise.
    $savedWhatIfPreference = $WhatIfPreference
    try { $WhatIfPreference = $false; Import-Module CimCmdlets -ErrorAction Stop } finally { $WhatIfPreference = $savedWhatIfPreference }
    if ($Repair -and -not $DryRun -and -not $WhatIfPreference -and -not (Test-Administrator)) { throw 'La riparazione reale richiede PowerShell avviato come amministratore.' }
    if (-not (Test-Path -LiteralPath $DriverRoot -PathType Container)) { throw "DriverRoot not found: $DriverRoot" }
    if ($Repair -and $CheckOnly) { throw 'Repair and CheckOnly cannot be used together.' }
    $bootstrapRan = $false

    $initialVideo = Get-OneInterface $VideoId
    $initialAudio = Get-OneInterface $AudioId
    Show-Interface $initialVideo 'Initial MI_00 video'
    Show-Interface $initialAudio 'Initial MI_01 audio'
    $videoState = Get-VideoDriverState $initialVideo
    $audioState = Get-AudioDriverState $initialAudio
    Write-Log "VideoDriverState: $videoState"
    Write-Log "AudioDriverState: $audioState"
    Get-DirectShowDevices
    Show-SimpleSummary -Video $initialVideo -Audio $initialAudio -VideoState $videoState -AudioState $audioState
    if (-not $Repair) { Write-Status 'Nessuna modifica eseguita. Per simulare: .\install-dazzle-dvc100.ps1 -Repair -WhatIf'; return }
    $needBootstrap = (-not $initialAudio) -or $audioState -in @('Missing','Error') -or ($script:FfmpegAvailable -and -not $script:DetectedDsAudio)
    if ($SkipBootstrap -and $needBootstrap) {
        Write-Status 'Bootstrap saltato su richiesta esplicita; MI_01 resta invariata. Si procedera solo con la riparazione video.'
        $needBootstrap = $false
    }
    Show-SimpleRepairPlan -Video $initialVideo -BootstrapNeeded $needBootstrap
    if ($needBootstrap) {
        Write-Log 'Audio policy: run only the validated local bootstrap MSI, then observe and preserve the MI_01 binding. No alternate audio INF is selected, added, removed, or forced.'
        $bootstrap = Get-ValidatedBootstrapPackage
        if (-not (Confirm-Explicit 'Open the validated Dazzle installer to restore audio prerequisites?')) { Write-Log 'Bootstrap cancelled by user.'; return }
        Write-RollbackReport -Current $initialAudio -Replacement ([pscustomobject]@{Path=$bootstrap.ExePath}) -Commands @('"' + $bootstrap.ExePath + '" (interactive)')
        $bootstrapped = Invoke-BootstrapInstaller -Bootstrap $bootstrap
        if (-not $bootstrapped) { Write-Log 'Bootstrap was not executed; no further repair action will run.' 'WARN'; return }
        $bootstrapRan = $true
        if ($DryRun -or $WhatIfPreference) {
            $simulationVideoPackage = Get-ValidatedVideoPackage
            Write-Status "Simulazione: EMBDA validato. Verrebbe eseguito: pnputil /add-driver `"$($simulationVideoPackage.Path)`" /install"
            Write-Status "Simulazione: il vecchio video $($initialVideo.InfName) verrebbe rimosso solo dopo nuove verifiche di esclusivita."
            Write-Status 'Simulazione completata: nessun pacchetto o dispositivo e stato modificato.'
            return
        }
        Read-Host 'Reconnect the Dazzle if necessary, then press Enter to scan for devices' | Out-Null
        Invoke-PnpUtilChange -Arguments @('/scan-devices') -Target 'Dazzle USB device enumeration' -Action 'Scan after bootstrap' | Out-Null
        $postBootstrap = Wait-ForInterfaces
        $initialVideo = $postBootstrap.Video; $initialAudio = $postBootstrap.Audio
        if (-not $initialAudio -or (Get-AudioDriverState $initialAudio) -notin @('Working','KnownStutteringDriver')) { throw 'Bootstrap completed but MI_01 is not OK. Audio and its INF will not be removed; manual intervention is required.' }
        Show-Interface $initialAudio 'Post-bootstrap MI_01 audio'
        Write-Log "Observed post-bootstrap MI_01 binding: InfName=$($initialAudio.InfName); Provider=$($initialAudio.DriverProviderName); Version=$($initialAudio.DriverVersion); Service=$($initialAudio.Service). This binding will be preserved."
        $script:ProtectedAudioInf = $initialAudio.InfName
    }
    $videoState = Get-VideoDriverState $initialVideo
    if ($videoState -eq 'Correct' -and -not $Force) {
        if ($bootstrapRan) { Write-Status 'Bootstrap completato. Riavvia Windows prima di testare nuovamente l audio; lo script non riavvia mai il PC automaticamente.' }
        Write-Log 'MI_00 already uses the validated EMBDA driver; no video action is required.'
        return
    }

    $replacement = Get-ValidatedVideoPackage
    if (-not $initialVideo) { Write-Log 'MI_00 is absent. The replacement may be staged, but final verification requires reconnecting the Dazzle.' 'WARN' }
    if ($initialVideo -and -not (Test-VideoRemovalIdentity -Video $initialVideo -Replacement $replacement)) { throw 'Fail-closed: MI_00 identity, package exclusivity, replacement identity, or current package safety could not be proven before staging. No change was made.' }
    $addCommand = @('/add-driver',$replacement.Path,'/install')
    $removeCommand = $(if ($initialVideo) { @('/delete-driver',$initialVideo.InfName,'/uninstall') } else { @() })
    Write-Log ("Repair plan: stage replacement first, then remove only the current MI_00 package if every safety condition remains true. Add={0}; Delete={1}" -f ('pnputil.exe ' + ($addCommand -join ' ')),$(if ($removeCommand.Count) { 'pnputil.exe ' + ($removeCommand -join ' ') } else { '<none>' }))
    Show-Interface $initialVideo 'Device involved in repair'
    if ($DryRun) {
        Write-Log ("DryRun planned replacement command: pnputil.exe {0}" -f ($addCommand -join ' ')) 'DRYRUN'
        if ($removeCommand.Count) { Write-Log ("DryRun planned deletion command: pnputil.exe {0}" -f ($removeCommand -join ' ')) 'DRYRUN' }
    }
    if (-not (Confirm-Explicit 'Proceed with staging the validated EMBDA package?')) { Write-Log 'Repair cancelled before staging.'; return }
    Write-RollbackReport -Current $initialVideo -Replacement $replacement -Commands @('pnputil.exe ' + ($addCommand -join ' '), 'pnputil.exe ' + ($removeCommand -join ' '))
    $added = Invoke-PnpUtilChange -Arguments $addCommand -Target $replacement.Path -Action 'Add and signature-validate replacement video package in Driver Store'
    if (-not $added) { Write-Log 'Replacement package was not added; no old package will be considered for removal.' 'WARN'; return }
    Write-RollbackReport -Current $initialVideo -Replacement $replacement -Commands @('pnputil.exe ' + ($addCommand -join ' '), 'pnputil.exe ' + ($removeCommand -join ' '))
    if ($DryRun -or $WhatIfPreference) { Write-Log 'Simulation complete. No Driver Store package was changed.' 'DRYRUN'; return }
    if (-not $initialVideo) { Write-Log 'Replacement staged. Connect the Dazzle and run -Repair again for final binding verification.' 'WARN'; return }
    $afterAddVideo = Get-OneInterface $VideoId
    if ((Get-VideoDriverState $afterAddVideo) -eq 'Correct') { Write-Log 'EMBDA associated successfully after staging; old package will not be deleted.'; return }
    if (-not $afterAddVideo -or $afterAddVideo.InfName -ne $initialVideo.InfName) { throw 'Fail-closed: MI_00 changed unexpectedly after staging. No deletion will be attempted.' }
    $initialVideo = $afterAddVideo
    if (-not (Test-SafeVideoRemoval -Video $initialVideo -Replacement $replacement -ReplacementAdded $true)) { throw "Fail-closed: the current video package cannot be proven exclusive and safe to remove. No deletion was attempted." }
    $users = @(Get-PackageUsers $initialVideo.InfName)
    $users | ForEach-Object { Write-Log "Verified package user: DeviceID=$($_.DeviceID); DeviceName=$($_.DeviceName)" }
    if (-not (Confirm-Explicit "SECOND CONFIRMATION: delete only published INF $($initialVideo.InfName) for MI_00?")) { Write-Log 'Repair stopped before deleting the old package. The EMBDA package remains staged.' 'WARN'; return }
    Write-RollbackReport -Current $initialVideo -Replacement $replacement -Commands @('pnputil.exe ' + ($addCommand -join ' '), 'pnputil.exe ' + ($removeCommand -join ' '))
    $removed = Invoke-PnpUtilChange -Arguments $removeCommand -Target $initialVideo.InfName -Action 'Delete exclusive legacy MI_00 video package'
    if (-not $removed) { Write-Log 'Old package was not deleted; no further action will be attempted.' 'WARN'; return }
    Read-Host 'Disconnect and reconnect the Dazzle USB device, then press Enter to scan for devices' | Out-Null
    Invoke-PnpUtilChange -Arguments @('/scan-devices') -Target 'Dazzle USB device enumeration' -Action 'Scan for connected devices' | Out-Null
    $final = Wait-ForInterfaces
    if (-not $final.Video -or -not $final.Audio) { throw 'Final verification failed: MI_00 and MI_01 did not both reappear. No additional automatic correction will be attempted.' }
    Show-Interface $final.Video 'Final MI_00 video'
    Show-Interface $final.Audio 'Final MI_01 audio'
    $finalVideoState = Get-VideoDriverState $final.Video
    $finalAudioState = Get-AudioDriverState $final.Audio
    Write-Log "Final VideoDriverState: $finalVideoState"
    Write-Log "Final AudioDriverState: $finalAudioState"
    if ($script:ProtectedAudioInf -and $final.Audio.InfName -ne $script:ProtectedAudioInf) { throw "Final verification failed: MI_01 binding changed from $script:ProtectedAudioInf to $($final.Audio.InfName). No additional automatic correction will be attempted; manual intervention is required." }
    if ($finalVideoState -ne 'Correct' -or $finalAudioState -notin @('Working','KnownStutteringDriver')) { throw "Final verification failed (Video=$finalVideoState; Audio=$finalAudioState). No additional automatic correction will be attempted; manual intervention is required." }
    Get-DirectShowDevices
    Write-Log 'Video repair completed successfully.'
} catch {
    Write-Log $_.Exception.Message 'ERROR'
    Write-Log "Failure location: $($_.ScriptStackTrace)" 'INFO'
    exit 1
} finally {
    if (Test-Path -LiteralPath $runRoot) { Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false }
    try { $summaryVideo=Get-OneInterface $VideoId; $summaryAudio=Get-OneInterface $AudioId; Show-Interface $summaryVideo 'Summary MI_00 video'; Show-Interface $summaryAudio 'Summary MI_01 audio'; Write-Log ("Summary VideoDriverState: {0}; AudioDriverState: {1}" -f (Get-VideoDriverState $summaryVideo),(Get-AudioDriverState $summaryAudio)) } catch { Write-Log "Could not collect final summary: $($_.Exception.Message)" 'WARN' }
    if ($Detailed) {
        Write-Host 'DirectShow check: ffmpeg -list_devices true -f dshow -i dummy'
        if ($script:DetectedDsVideo -and $script:DetectedDsAudio) { Write-Host ('PAL B S-Video preview: ffplay -f dshow -crossbar_video_input_pin_number 2 -video_size 720x576 -framerate 25 -i "video={0}:audio={1}" -vf "yadif=1:-1:0" -sync audio' -f $script:DetectedDsVideo,$script:DetectedDsAudio) }
    }
    if ($script:RollbackPath) { Write-Host "Rollback report: $script:RollbackPath" }
    if ($script:Actions.Count) { Write-Host ('Actions: ' + ($script:Actions -join '; ')) }
}
