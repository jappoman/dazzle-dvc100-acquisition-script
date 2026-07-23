# Dazzle DVC100: driver e acquisizione Hi8

Procedura verificata per Windows 11 a 64 bit per installare correttamente la Dazzle DVC100 e acquisire nastri Hi8 da ingresso S-Video. Il repository contiene sia i driver necessari sia lo script PowerShell che crea un file video e interrompe l'acquisizione quando rileva assenza di segnale.

## Contenuto

| Percorso | Scopo |
| --- | --- |
| `drivers/Dazzle Drivers/Dazzle Video Capture DVC100 X64 Driver 1.09.msi` | Pacchetto driver audio di base |
| `drivers/usb-2828x-1176289/EMBDA_x86_x64.inf` | Driver video corretto per questa revisione hardware |
| `acquisisci-hi8-auto-stop.ps1` | Acquisizione PAL con deinterlacciamento e arresto automatico |

## Requisiti

- Windows 11 64 bit.
- Dazzle DVC100 con ID hardware `USB\\VID_1B80&PID_E60A`.
- [FFmpeg](https://ffmpeg.org/) disponibile nel `PATH` (`ffmpeg -version`).
- Una sorgente Hi8 collegata alla Dazzle tramite **S-Video** e audio stereo.
- PowerShell; sono necessari privilegi di amministratore solo per installare i driver.

> Questa guida vale per `VID_1B80&PID_E60A`. Non usare `EMVIDEO.inf`: è destinato alla vecchia revisione `VID_2304&PID_021A`.

## Installazione dei driver

1. Scollega la Dazzle.
2. In Gestione dispositivi disinstalla soltanto eventuali periferiche Dazzle con questi ID:
   - `USB\\VID_1B80&PID_E60A&MI_00` (video)
   - `USB\\VID_1B80&PID_E60A&MI_01` (audio)

   Se proposto, rimuovi anche il software driver. Non rimuovere il dispositivo USB composito generico né altre periferiche USB.
3. Esegui come amministratore `drivers/Dazzle Drivers/Dazzle Video Capture DVC100 X64 Driver 1.09.msi` e completa l'installazione.
4. Collega la Dazzle direttamente a una porta USB del PC e attendi circa 10 secondi.
5. Apri PowerShell come amministratore dalla radice del repository ed esegui:

   ```powershell
   pnputil /add-driver ".\drivers\usb-2828x-1176289\EMBDA_x86_x64.inf" /install
   pnputil /scan-devices
   ```

6. Verifica lo stato dei dispositivi:

   ```powershell
   Get-PnpDevice -PresentOnly |
     Where-Object { $_.InstanceId -match 'VID_1B80&PID_E60A' } |
     Format-Table Status, Class, FriendlyName, InstanceId -AutoSize
   ```

   Il dispositivo video (`MI_00`), l'audio (`MI_01`) e il dispositivo USB composito devono avere stato `OK`.
7. Verifica il driver video:

   ```powershell
   Get-CimInstance Win32_PnPSignedDriver |
     Where-Object { $_.DeviceID -like '*VID_1B80&PID_E60A&MI_00*' } |
     Format-List DeviceName, DriverProviderName, DriverVersion, DriverDate, InfName
   ```

   Il risultato atteso riporta `Corel Corporation` e versione `5.2020.406.1015`. Il nome `oem*.inf` può variare.

## Verifica con FFmpeg

Elenca i dispositivi DirectShow:

```powershell
ffmpeg -list_devices true -f dshow -i dummy
```

Devono comparire:

- `Roxio Video Capture USB`
- `Linea (Dazzle Video Capture USB Audio Device)`

L'errore finale relativo a `dummy` è normale. Per una preview video/audio:

```powershell
ffplay -f dshow -crossbar_video_input_pin_number 2 `
  -video_size 720x576 -framerate 25 `
  -i "video=Roxio Video Capture USB:audio=Linea (Dazzle Video Capture USB Audio Device)" `
  -vf "yadif=1:-1:0" -sync audio
```

## Acquisizione

Lo script registra in MKV H.264/AAC, converte il PAL interlacciato 25 fps in progressivo 50 fps con YADIF e salva anche un log. L'output predefinito è `F:\Hi8`; la cartella viene creata se manca.

Se necessario, abilita l'esecuzione soltanto per la sessione corrente:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
Unblock-File .\acquisisci-hi8-auto-stop.ps1  # solo se Windows lo ha bloccato
```

Avvio standard:

```powershell
.\acquisisci-hi8-auto-stop.ps1
```

Esempio completo:

```powershell
.\acquisisci-hi8-auto-stop.ps1 `
  -OutputDirectory "F:\Hi8" `
  -MaxDuration "01:30:00" `
  -NoSignalDuration "00:00:45"
```

Parametri principali:

| Parametro | Predefinito | Descrizione |
| --- | --- | --- |
| `OutputDirectory` | `F:\Hi8` | Cartella per MKV e log |
| `MaxDuration` | 90 minuti | Durata massima |
| `NoSignalDuration` | 45 secondi | Durata continua di nero o fermo immagine prima dello stop |
| `RequireSilence` | `false` | Se impostato a `true`, richiede anche silenzio audio prima dello stop |
| `SilenceThresholdDb` | `-45` | Soglia del silenzio |
| `Crf` / `Preset` | `22` / `medium` | Qualità e velocità H.264 |

Premi **Q** nella console per fermare manualmente e permettere a FFmpeg di finalizzare il file. Evita di chiudere PowerShell o terminare `ffmpeg` dal Task Manager.

## Arresto automatico

Fin dall'inizio dell'acquisizione, lo script richiede lo stop quando rileva per la soglia impostata:

- schermo nero **oppure** immagine congelata;
- opzionalmente, anche audio silenzioso nello stesso intervallo (`-RequireSilence $true`).

Il conteggio usa il tempo reale, non il timestamp del video codificato. Abilitare anche il silenzio riduce il rischio di fermare una scena nera o una ripresa statica legittima. Il limite massimo resta una protezione aggiuntiva.

## File prodotto e controllo finale

Il file ha dimensioni 768×576, pixel quadrati 4:3, 50 fps progressivi, video H.264 (`CRF 22`) e audio AAC stereo 128 kbps. Controllalo con VLC oppure:

```powershell
ffprobe -v error -show_entries format=duration,size `
  -show_entries stream=index,codec_name,codec_type,width,height,r_frame_rate `
  -of default=noprint_wrappers=1 "F:\Hi8\nome-file.mkv"
```

L'output atteso include video `h264` a `768x576`, `50/1`, e audio `aac`.

## Problemi comuni

- **Video nero:** conferma l'ingresso S-Video e il pin `-crossbar_video_input_pin_number 2`.
- **`MI_00` in errore:** ripeti l'installazione di `EMBDA_x86_x64.inf`, poi esegui `pnputil /scan-devices`.
- **Stop troppo precoce:** aumenta `NoSignalDuration` (ad esempio `00:01:30`).
- **FFmpeg non trovato:** installalo e riapri PowerShell, quindi controlla con `ffmpeg -version`.
- **Frame drop in crescita:** collega la Dazzle senza hub USB non alimentati e verifica carico CPU e spazio su disco.

Durante l'acquisizione non scollegare Dazzle, videocamera o disco di destinazione e disattiva sospensione/ibernazione del PC.
