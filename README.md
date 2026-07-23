# Dazzle DVC100 — procedura guidata, conservativa e fail-closed

Lo script gestisce esclusivamente la Dazzle `USB\VID_1B80&PID_E60A`:

- `USB\VID_1B80&PID_E60A&MI_00`: video;
- `USB\VID_1B80&PID_E60A&MI_01`: audio.

Il comportamento predefinito è sola diagnosi. Aprire PowerShell come amministratore ed eseguire:

```powershell
.\install-dazzle-dvc100.ps1
```

Per autorizzare la sequenza guidata realmente riparativa:

```powershell
# Simulazione senza modifiche
.\install-dazzle-dvc100.ps1 -Repair -WhatIf

# Riparazione guidata, con conferme e report di rollback
.\install-dazzle-dvc100.ps1 -Repair
```

Sono supportati anche `-CheckOnly`, `-DryRun`, `-SkipPrompt`, `-TimeoutSeconds` e `-LogPath`. `-RepairVideo` resta un alias compatibile di `-Repair`.

## Pacchetti ispezionati

Entrambi gli archivi locali vengono usati solo dal repository:

- `drivers\Dazzle Drivers.zip` contiene `DazzleDVC100.exe`, launcher InstallShield firmato Pinnacle v1.09, e `Dazzle Video Capture DVC100 X64 Driver 1.09.msi`, MSI firmato validamente da Centron Design e dichiarato come produttore Pinnacle.
- Il ProductCode MSI è `{FB4B9EB9-68B2-4C42-8C38-B65F8FE5A5CA}`; l'UpgradeCode è `{34408E17-C98F-432C-8195-4F4CD532A383}`.
- L'MSI contiene `Data1.cab`, azioni DIFx `ProcessDriverPackages` e `InstallDriverPackages`, e i componenti driver `EMAUDIO_x86_x64_INF` e `EMVIDEO_INF`.
- `drivers\usb-2828x-1176289.zip` contiene `EMBDA_x86_x64.inf`, `emWHQL.cat`, `emBDA64.sys`, `emOEM64.sys` e `merlinFW.rom`. L'INF dichiara esattamente `USB\VID_1B80&PID_E60A&MI_00`.

Il launcher EXE non espone opzioni silenziose determinabili con sicurezza. Quando il bootstrap è necessario, lo script apre quindi `DazzleDVC100.exe` in modalità **interattiva** e attende la sua chiusura: è il comportamento che riproduce la procedura manuale riuscita. Non viene usato `/reboot`. L'analisi statica dimostra che l'MSI installa pacchetti DIFx, ma non può dimostrare quale binding audio Windows sceglierà al runtime. Lo script **non cerca né inventa un INF audio alternativo**: esegue esclusivamente il bootstrap locale, osserva provider/versione/servizio/INF realmente associati a `MI_01` dopo il bootstrap e conserva esattamente quel binding.

## Sequenza di riparazione

Con `-Repair`, lo script:

1. diagnostica entrambe le interfacce: status, problem code, friendly name, provider, versione/data, INF pubblicato, servizio, ClassGuid, hardware e compatible IDs;
2. esegue il bootstrap solo se `MI_01` è assente/in errore oppure FFmpeg, quando disponibile, prova l'assenza dell'endpoint DirectShow audio;
3. dopo il bootstrap esegue `pnputil /scan-devices`, richiede il ricollegamento se necessario, attende entrambe le interfacce e registra il binding audio ottenuto; `MI_01`, il suo INF e ogni endpoint audio non vengono mai rimossi, sostituiti o forzati;
4. estrae EMBDA, verifica INF, catalogo firmato e file necessari, poi aggiunge/installla il pacchetto con `pnputil /add-driver "<INF>" /install`;
5. se EMBDA non si associa, elimina il vecchio pacchetto video solo se è associato esattamente a `MI_00`, non è Microsoft e non è usato da alcun altro dispositivo; se il pacchetto è condiviso interrompe senza eliminarlo;
6. chiede scollegamento/ricollegamento, effettua la scansione e verifica `MI_00` con EMBDA e `MI_01` ancora `OK` e associata allo stesso INF post-bootstrap.

Al termine di un bootstrap o di una sostituzione driver, lo script non riavvia mai automaticamente il PC: richiede invece un riavvio manuale completo prima della prova audio finale.

Se `MI_01` resta sul driver Pinnacle `emAudio` 5.2012.416.2725 e l'audio stuttera anche dopo il riavvio, il repository non contiene un INF audio compatibile alternativo. Lo script non ripete bootstrap, non rimuove l'audio e non tenta sostituzioni non validate: l'unica soluzione pratica è acquisire l'audio con un ingresso line-in o un'interfaccia USB audio separata e usare la Dazzle per il solo video.

Se EMBDA si associa dopo lo staging, il vecchio INF video non viene eliminato. Se un controllo è ambiguo, incompleto o produce più risultati, il flusso si arresta senza rimozioni.

## Vincoli di sicurezza

Ogni modifica usa `SupportsShouldProcess` con `ConfirmImpact High`, presenta un piano e crea un report JSON accanto al log prima e dopo ogni modifica. Il report è storico e **non promette rollback automatico** se un pacchetto è stato eliminato dal Driver Store.

Non vengono mai usati `/force`, wildcard con `/delete-driver`, modifiche al registro o agli INF, bcdedit, disabilitazione firma, `Disable-PnpDevice`, `Remove-PnpDevice`, rimozione del dispositivo composito, rimozione di `MI_01`, rimozione driver audio o riavvio automatico. `-SkipPrompt` da solo non elimina le conferme; l’unica combinazione non interattiva è `-SkipPrompt -Force`, che non rende comunque eliminabile un pacchetto condiviso.

`-DryRun` riporta il dispositivo coinvolto, InstanceId, ID hardware, INF pubblicato, provider, versione, servizio e i comandi che sarebbero eseguiti. `-WhatIf` usa il meccanismo nativo PowerShell.

## DirectShow e test PAL B

Se `ffmpeg.exe` è nel `PATH`, lo script esegue:

```powershell
ffmpeg -list_devices true -f dshow -i dummy
```

Il risultato atteso è `Roxio Video Capture USB` e `Linea (Dazzle Video Capture USB Audio Device)`. Il FriendlyName PnP e il nome DirectShow possono differire, quindi il nome non è il solo criterio per il binding video. La verifica EMBDA accetta il binding effettivo `USB28xxBGA` con binario firmato `emBDA64.sys`, perché Windows può conservare metadati Pinnacle nel record PnP pubblicato dopo la sostituzione del pacchetto.

Per PAL B da S-Video il pin crossbar corretto è **2**:

```powershell
ffplay -f dshow -crossbar_video_input_pin_number 2 -video_size 720x576 -framerate 25 -i "video=Roxio Video Capture USB:audio=Linea (Dazzle Video Capture USB Audio Device)" -vf "yadif=1:-1:0" -sync audio
```
