# Dazzle DVC100 capture workflow

Two PowerShell scripts turn analogue video from a Dazzle DVC100 into client-ready
copies without recompressing the recorded video or audio.

1. `capture-dazzle.ps1` captures from the Dazzle device.
2. `finalize-dazzle-captures.ps1` scans the captured masters and writes the
   delivery-ready copies to the outer folder, shortening long black gaps to
   five seconds.

The source may be a Hi8/Video8 camera, VHS player, or any other analogue source
connected to the Dazzle. The workflow is named after the capture device, not a
specific tape format.

## Requirements

- Windows 11 64-bit.
- Dazzle DVC100 with hardware ID `USB\VID_1B80&PID_E60A`.
- FFmpeg on `PATH` (`ffmpeg -version` and `ffprobe -version`).
- Enough free disk space for both the captures and their finalised copies.

The supplied driver archives are retained unchanged in `drivers/`:

- `Dazzle Drivers.zip` contains the DVC100 64-bit installer.
- `usb-2828x-1176289.zip` contains `EMBDA_x86_x64.inf` for the video interface.

Do not use `EMVIDEO.inf` for this DVC100 hardware revision.

## Install and check the device

Install the Dazzle audio driver, then install the supplied video INF from an
elevated PowerShell session. Confirm the Dazzle is detected with:

```powershell
Get-PnpDevice -PresentOnly |
  Where-Object { $_.InstanceId -match 'VID_1B80&PID_E60A' } |
  Format-Table Status, Class, FriendlyName, InstanceId -AutoSize
```

List the DirectShow device names:

```powershell
ffmpeg -list_devices true -f dshow -i dummy
```

On the tested Italian installation the defaults are:

- Video: `Roxio Video Capture USB`
- Audio: `Linea (Dazzle Video Capture USB Audio Device)`

Pass `-VideoDevice` or `-AudioDevice` if Windows reports different names.

## 1. Capture

For the current PowerShell session, if needed:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

Capture a labelled tape:

```powershell
.\capture-dazzle.ps1 `
  -TapeLabel 'C32' `
  -ContentDescription 'Kenya, March 2001'
```

By default the script writes to `F:\DazzleCapture\master`:

- `dazzle-capture-YYYY-MM-DD_HH-mm-ss - C32.mkv`
- matching capture log
- `index.txt`, containing the label and description

It captures PAL video as deinterlaced 50 fps H.264 with AAC stereo audio.
Press **Q** to finish a capture cleanly.

### Mono tapes captured on one channel

Some mono VHS recordings may arrive from the capture device as a two-channel
stream with programme audio present only on the left or right channel. Use
`-MonoSourceChannel Left` or `-MonoSourceChannel Right` to duplicate that source
channel to both channels of the AAC stereo output.

For example, if the programme audio is present only on the right channel:

```powershell
.\capture-dazzle.ps1 `
  -TapeLabel 'VHS1' `
  -ContentDescription 'Margherita Pesciolino 1o anno di scuola materna 99/00' `
  -MonoSourceChannel Right
```

The default is `-MonoSourceChannel None`, which leaves normal stereo captures
unchanged.

### Automatic stop defaults

The capture stops after **two continuous minutes** of a black or frozen picture
*and* quiet audio. The audio threshold is `-20 dB`, calibrated to treat the
Dazzle's steady analogue no-signal noise as silence while ordinary programme
audio remains above it.

The independent two-hour maximum remains a safety limit. Useful overrides:

```powershell
.\capture-dazzle.ps1 -NoSignalDuration '00:03:00'
.\capture-dazzle.ps1 -RequireSilence $false
```

## 2. Finalise copies

After capturing a batch, run:

```powershell
.\finalize-dazzle-captures.ps1 -InputDirectory 'F:\DazzleCapture\master'
```

The script writes the delivery-ready files directly to `F:\DazzleCapture`.
It never edits, renames, or deletes an input MKV. For each capture it:

- detects black runs of at least 10 seconds;
- retains at most 5 seconds of every internal black gap;
- retains at most 5 seconds of final black;
- creates the result only with FFmpeg stream copy (`-c copy`), so neither video
  nor audio is re-encoded;
- writes a client-facing `catalogo-cassette.csv` with file name, content
  description, and final duration.

Choose another destination if desired; it must not already exist:

```powershell
.\finalize-dazzle-captures.ps1 `
  -InputDirectory 'F:\DazzleCapture\master' `
  -OutputDirectory 'F:\Consegna-cliente'
```

Stream copy can cut only on nearby H.264 keyframes, so the retained five seconds
are approximate by a few seconds. That is the trade-off for preserving the
original encoded audio and video exactly. The script deliberately processes one
input file into one output file; joining separately acquired continuations is an
editorial choice and should be done after checking their content.

The resulting structure is deliberately client-friendly:

```text
F:\DazzleCapture\
  dazzle-capture-... - C32.mkv
  catalogo-cassette.csv
  master\
    dazzle-capture-... - C32.mkv
    dazzle-capture-... - C32.log
    index.txt
```

## Troubleshooting

- No picture: check the analogue connection and use `-CrossbarPin 2` for
  S-Video.
- Audio/video device not found: run the DirectShow listing command and pass the
  exact reported name.
- Stop occurs too early: increase `-NoSignalDuration`.
- Capture never stops at end of tape: confirm the audio cable/device works;
  automatic stop intentionally requires both no video and quiet audio by
  default.
- FFmpeg missing: install it, reopen PowerShell, and verify `ffmpeg -version`.
