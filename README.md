# Dazzle DVC100 Hi8 Capture for Windows 11

Capture PAL Hi8 tapes from a Dazzle DVC100 on Windows 11 x64. This repository
contains the known-working driver packages and a PowerShell capture script that
writes a high-quality MKV file, a log, and a searchable tape index. It can stop
the capture automatically after two continuous minutes of black/frozen and
silent audio.

## What is included

| Path | Purpose |
| --- | --- |
| `capture-hi8.ps1` | PAL capture, deinterlacing, automatic stop, index update, and optional computer shutdown |
| `audit-hi8.ps1` | Read-only audit of captured MKVs: stream/decode integrity, capture grouping, duration, and final-black-tail check |
| `drivers/Dazzle Drivers.zip` | Driver installer archive; contains `Dazzle Video Capture DVC100 X64 Driver 1.09.msi` |
| `drivers/usb-2828x-1176289.zip` | Video driver archive; contains `EMBDA_x86_x64.inf` |

The files inside the supplied vendor archives retain their original names. Do
not rename the `.msi`, `.inf`, `.sys`, or `.cat` files after extracting them.

### Driver sources

The archives deliberately retain their original download names, making them
easier to locate or verify online. The installer archive (`Dazzle Drivers.zip`)
was obtained from the [VideoHelp Dazzle DVC100 discussion](https://forum.videohelp.com/threads/398965-Dazzle-DVC100-not-capturing-anymore-on-Windows-10#post2603674).
The video-driver archive (`usb-2828x-1176289.zip`) was obtained from the
[DriverIdentifier Dazzle video-device driver page](https://www.driveridentifier.com/scan/dazzle-video-capture-usb-video-device-driver/driver-detail/440EF39A8C51443ABDF94C39458120B4/4721701/15b9d95803ef0a6cef210fd7cd28007c/790176020/USB-VID_1B80%26PID_E60A%26MI_00).

## Requirements

- Windows 11 64-bit.
- Dazzle DVC100 with hardware ID `USB\VID_1B80&PID_E60A`.
- A Hi8 camera/player connected by **S-Video** and stereo audio.
- [FFmpeg](https://ffmpeg.org/) available on `PATH`; verify with `ffmpeg -version`.
- Sufficient free space on the destination drive (approximately 6.3 Mb/s with
  the default settings, or about 2.8 GB per hour).

Administrator rights are required only to remove/install drivers. A normal
PowerShell session is sufficient for capturing and for scheduling shutdown.

> [!NOTE]
> The script defaults were tested with the Italian Windows 11 Dazzle-driver
> installation described below. In that installation, DirectShow exposes the
> audio input exactly as `Linea (Dazzle Video Capture USB Audio Device)`.
> This is a device name supplied by the driver, not text translated by the
> script: do not replace `Linea` with `Line` on that Italian installation.

> [!IMPORTANT]
> These driver instructions apply only to `VID_1B80&PID_E60A`. Do not install
> `EMVIDEO.inf` for this hardware revision: it belongs to the older
> `VID_2304&PID_021A` revision.

## Windows 11 x64 driver installation

Follow this order exactly. Connect the Dazzle directly to the computer rather
than through an unpowered USB hub.

1. Disconnect the Dazzle from USB.
2. Open **Device Manager** as an administrator. If previous Dazzle drivers are
   present, uninstall only devices whose IDs start with one of these values:

   - `USB\VID_1B80&PID_E60A&MI_00` — video interface
   - `USB\VID_1B80&PID_E60A&MI_01` — audio interface

   Select **Attempt to remove the driver for this device** if Windows offers it.
   Do not remove an unrelated USB device or the generic USB Composite Device.
3. Extract `drivers/Dazzle Drivers.zip` to a temporary folder.
   Right-click `Dazzle Video Capture DVC100 X64 Driver 1.09.msi`, choose
   **Run as administrator**, and complete the installer.
4. Connect the Dazzle directly to a USB port and wait about 10 seconds.
5. Extract `drivers/usb-2828x-1176289.zip` to a temporary folder.
   Open **PowerShell as administrator**, replace `$videoDriverFolder` with that
   extracted folder, then install the video INF:

   ```powershell
$videoDriverFolder = 'C:\Temp\usb-2828x-1176289'
   pnputil /add-driver "$videoDriverFolder\EMBDA_x86_x64.inf" /install
   pnputil /scan-devices
   ```

6. Confirm that the Dazzle interfaces are working:

   ```powershell
   Get-PnpDevice -PresentOnly |
     Where-Object { $_.InstanceId -match 'VID_1B80&PID_E60A' } |
     Format-Table Status, Class, FriendlyName, InstanceId -AutoSize
   ```

   The `MI_00` video interface, `MI_01` audio interface, and USB composite
   device should report `OK`.
7. Confirm the video-driver binding:

   ```powershell
   Get-CimInstance Win32_PnPSignedDriver |
     Where-Object { $_.DeviceID -like '*VID_1B80&PID_E60A&MI_00*' } |
     Format-List DeviceName, DriverProviderName, DriverVersion, DriverDate, InfName
   ```

   On the tested hardware, this reports `Corel Corporation`, driver version
   `5.2020.406.1015`, and a Windows-assigned `oem*.inf` name. The exact INF
   name is not significant.

## Verify the capture devices

List DirectShow devices:

```powershell
ffmpeg -list_devices true -f dshow -i dummy
```

The expected device names are:

- `Roxio Video Capture USB`
- `Linea (Dazzle Video Capture USB Audio Device)`

The final error mentioning `dummy` is expected. If your device names differ,
pass them through `-VideoDevice` and `-AudioDevice`. The first word of the
audio device can be localized by Windows; for example, an English Windows
installation may display `Line (Dazzle Video Capture USB Audio Device)`.

For a video/audio preview:

```powershell
ffplay -f dshow -crossbar_video_input_pin_number 2 `
  -video_size 720x576 -framerate 25 `
  -i "video=Roxio Video Capture USB:audio=Linea (Dazzle Video Capture USB Audio Device)" `
  -vf "yadif=1:-1:0" -sync audio
```

## Capture a tape

If Windows blocks local scripts, enable execution for this PowerShell session
only:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
Unblock-File .\capture-hi8.ps1  # only if the file is blocked
```

Start a capture with all defaults:

```powershell
.\capture-hi8.ps1
```

Example with tape metadata and automatic shutdown:

```powershell
.\capture-hi8.ps1 `
  -TapeLabel 'C32' `
  -ContentDescription 'Kenya, March 2001' `
  -MaxDuration '02:00:00' `
  -NoSignalDuration '00:02:00' `
  -ShutdownOnCompletion $true
```

Press **Q** in the console to stop cleanly and let FFmpeg finalize the file.
Do not close PowerShell or end `ffmpeg` from Task Manager while a capture is in
progress.

While recording, PowerShell updates the progress display once per second. `Wall`
is the real elapsed capture time and advances independently of FFmpeg's progress
reports. `Encoded` is the duration reported by FFmpeg and can trail by a few
seconds while frames are buffered or encoded. The display also shows encoded
frames, encoding FPS, speed, bitrate, output size, duplicated/dropped frames,
DirectShow buffer warnings, and black/frozen/silent-signal timers. The black and
freeze timers are always visible: they remain at `0s` with a normal signal and
increase only while a condition is detected. `Drop` is FFmpeg's
synchronization/encoding counter; it is not necessarily a hardware loss reported
by the Dazzle. Device warnings are counted separately when DirectShow reports a
full real-time buffer or frame drop in its log output.

### Parameters and defaults

All output locations are parameters. With no arguments, the script creates
`F:\Hi8` if needed, then writes the MKV, log, and `index.txt` there. A custom
log directory or index-file path is created automatically when its parent
directory does not already exist.

| Parameter | Default | Description |
| --- | --- | --- |
| `OutputDirectory` | `F:\Hi8` | Destination directory for the MKV, log, and `index.txt`. Created if absent. |
| `LogDirectory` | empty (uses `OutputDirectory`) | Directory for capture log files. Created if absent. |
| `IndexFile` | empty (uses `OutputDirectory\index.txt`) | File path for the capture index. Its parent directory is created if absent. |
| `TapeLabel` | empty | Optional label added to the MKV and log names, for example ` - C32`. Must be valid in a Windows file name. `Comment` is a backwards-compatible alias. |
| `ContentDescription` | empty | Optional index description. It follows the filename after a tab character; tabs and line breaks are rejected. `IndexComment` is a backwards-compatible alias. |
| `MaxDuration` | `02:00:00` | Hard upper limit for the capture. Must be greater than zero. |
| `NoSignalDuration` | `00:02:00` | Continuous black/frozen-picture time before automatic stop. Minimum: 20 seconds. |
| `RequireSilence` | `$true` | Automatic stop requires silent audio for the same duration as the black/frozen picture. |
| `NotifyOnCompletion` | `$true` | Plays audible completion/error alerts. |
| `NotificationRepeatCount` | `2` | Number of alerts, from 1 through 10. |
| `ShutdownOnCompletion` | `$false` | Schedules a shutdown 30 seconds after a successful capture. Applications are force-closed; cancel with `shutdown /a`. |
| `SilenceThresholdDb` | `-20` | Audio level below which FFmpeg considers the input silent. The analogue-friendly default treats the Dazzle's steady no-signal noise as silence. Must be negative. |
| `VideoDevice` | `Roxio Video Capture USB` | DirectShow video device name. |
| `AudioDevice` | `Linea (Dazzle Video Capture USB Audio Device)` | DirectShow audio device name on the tested Italian Windows installation. It may be localized; use the name shown by FFmpeg on other systems. |
| `CrossbarPin` | `2` | DirectShow crossbar input pin for S-Video. |
| `Crf` | `22` | H.264 quality level, from 0 (highest quality/largest files) to 51. |
| `Preset` | `medium` | x264 encoding preset: `ultrafast`, `superfast`, `veryfast`, `faster`, `fast`, `medium`, `slow`, `slower`, or `veryslow`. |

The output filename uses this form:

```text
hi8-capture-YYYY-MM-DD_HH-mm-ss - TapeLabel.mkv
```

For example, a capture with `-TapeLabel 'C32'` produces
`hi8-capture-2026-07-25_01-26-29 - C32.mkv` and a matching `.log` file. Each
successful capture also adds an entry to `index.txt`, such as:

```text
hi8-capture-2026-07-25_01-26-29 - C32    Kenya, March 2001
```

There is a real tab between the filename and description. If no description is
provided, the index contains only the filename without the extension.

## Automatic stopping

From the beginning of the capture, the script stops after the configured
two-minute duration when it detects either:

- a continuous black screen; or
- a continuous frozen picture.

By default, the audio must also be silent for the same duration. This reduces
the chance of stopping during an intentional black or static scene.
`MaxDuration` always remains a separate safety limit. Pass
`-RequireSilence $false` only when a black/frozen picture alone should stop a
capture.

## Output format and validation

The default output is a Matroska (`.mkv`) file with H.264 video and AAC stereo
audio. PAL input is deinterlaced from 25 interlaced fps to 50 progressive fps,
scaled to 768×576 with square pixels (4:3).

Validate a finished file with:

```powershell
ffprobe -v error -show_entries format=duration,size `
  -show_entries stream=index,codec_name,codec_type,width,height,r_frame_rate `
  -of default=noprint_wrappers=1 'F:\Hi8\hi8-capture-example.mkv'
```

Expected video properties include `h264`, `768x576`, and `50/1`; the audio
codec is `aac`.

## Audit an existing Hi8 folder

`audit-hi8.ps1` never changes or re-encodes an MKV. It reads `index.txt`,
groups multiple files belonging to the same tape (for example a resumed C10
capture), measures the real durations with `ffprobe`, checks whether each
final file ends with the expected black tail, and writes an Excel-friendly CSV
summary.

Run it from the repository while the capture drive is connected:

```powershell
.\audit-hi8.ps1 -InputDirectory 'F:\Hi8'
```

It creates `F:\Hi8\hi8-audit.csv` (one row per tape) and
`F:\Hi8\hi8-audit.captures.csv` (one row per MKV). By default it also does a
full decode of every file; this is read-only but can take several hours for a
large collection. For a faster first pass, skip that part:

```powershell
.\audit-hi8.ps1 -InputDirectory 'F:\Hi8' -SkipDecodeCheck
```

`OK` means the grouped capture is at least 50 minutes long and its final file
has at least 40 seconds of black at the end. `CHECK_SHORT` means only that the
tape is short and merits a quick physical end-of-tape check; it does not prove
anything was lost. `CHECK_END` means the expected final black tail was not
found. `SPLIT_CAPTURE` marks a tape with more than one file, so resumed C10
and C22 captures are clear in the report. Adjust the two thresholds when
needed with `-MinimumExpectedDurationMinutes` and
`-ExpectedBlackTailSeconds`.

To generate a SHA-256 manifest of the masters at the same time (an additional
full read of every MKV), add `-CreateHashes`.

## Troubleshooting

- **No video or black video:** verify the S-Video connection and use
  `-CrossbarPin 2`.
- **Video interface (`MI_00`) has an error:** repeat the video-driver INF
  installation, then run `pnputil /scan-devices`.
- **Device name not found:** run the DirectShow device-list command and pass
  the displayed values to `-VideoDevice` and `-AudioDevice`.
- **Audio device `Line (...)` is not found on Italian Windows:** use the
  default `Linea (Dazzle Video Capture USB Audio Device)` name. The script is
  already configured with that exact default.
- **Automatic stop occurs too early:** increase `-NoSignalDuration`, for
  example to `00:03:00`. The default already requires two minutes of both
  no-video and silent audio.
- **FFmpeg is not found:** install FFmpeg, reopen PowerShell, and run
  `ffmpeg -version`.
- **Increasing dropped frames:** avoid unpowered USB hubs; check CPU use, USB
  bandwidth, and free space on the output drive.
- **The computer does not shut down:** verify no one ran `shutdown /a`; the
  script now reports a failure from `shutdown.exe` instead of silently ignoring it.

Do not disconnect the Dazzle, camera/player, or output drive during capture.
Disable sleep and hibernation for long tape transfers.
