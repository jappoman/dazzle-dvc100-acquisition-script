# Diagnosing and repairing temporal flashes

A temporal flash is a short return to an earlier picture during a continuous
scene. Distinguish it from ordinary cuts, interlacing lines, exposure changes
and analogue static before attempting an automatic repair.

## Diagnose a short passage

Keep the original capture. Compare the same passage in another player and, when
possible, directly on a display connected to the analogue source. Check capture
logs for buffer warnings, timestamp errors and duplicated/dropped-frame counters.
Zero counters do not prove that the received pictures are correct.

`capture-dazzle.ps1` offers two separate timing choices:

- `-VideoFrameRateMode Passthrough` avoids output frame-rate compensation;
  `Cfr` allows FFmpeg to duplicate or discard frames to enforce constant timing.
- `-VideoTimestampSource Wallclock` uses the PC clock for video timestamps;
  `Device` uses the capture device's timestamps. Changing the clock does not
  recover pictures already corrupted upstream.

For a diagnostic recording that bypasses H.264, deinterlacing and resizing:

```powershell
.\tools\diagnostics\capture-dazzle-diagnostic.ps1 -OutputDirectory '.\diagnostics' -DurationSeconds 60
```

This records video only, as FFV1 at 720x576, with sequential 25 fps timestamps.
It retains received pictures, but deliberately replaces their arrival timing.
It is not an audio/video synchronization test or a delivery master. Interlacing
lines may be visible. Keep these tests separate from the masters to finalise.

If earlier images remain in decoded diagnostic frames, investigate the source,
signal and capture path. An exact match with an earlier decoded picture can
suggest stale buffers, but does not identify a specific faulty component.

## Analyse an existing recording

The repair workflow supports **uniform 50 fps video**, such as deinterlaced PAL
captures. It rejects irregular timing; it does not silently convert a variable
frame-rate recording. The first video timestamp must also fall on the 20 ms
output grid, so repair cannot shift it by rounding. The grayscale detector loads the analysis into memory:
allow RAM for the dump and keep it below 2 GB (roughly 3.8 hours at 50 fps).

```powershell
.\tools\repair\analyze-video-flashes.ps1 -InputFile 'D:\Video\TAPE001.mkv' -AnalysisDirectory '.\repairs\analysis'
```

The analysis directory must be new or empty. The tool writes:

- `source.json`: source identity, frame count and verified timing;
- `analysis.gray` and `analysis.framehash`: reduced pictures and timestamps;
- `candidates.csv`: detection intervals and similarity scores;
- `episodes.csv`: merged replacement intervals to review before encoding.

The detector compares image content, not a fixed periodic frame number. It looks
for a short departure from neighbouring pictures, a close match to an image
0.16–1 second earlier, and continuation of the interrupted scene. Detection uses
64x48 grayscale images, excludes the borders, and considers runs up to 0.16 s.
All thresholds are in `tools/repair/FlashRepairAnalysis.cs`.

`-BridgeRatio` controls how much movement between the pictures before and after
an episode is accepted (default 1.10). Lower values are more conservative but can
miss flashes during fast camera movement. Higher values require extra review.
Automatic detection can miss faults or flag legitimate content.

## Review and repair

Inspect representative candidates at full resolution, including weak matches,
scene transitions and rapid movement. CSV frame indices start at zero; the
timestamp is `VideoStartSeconds + frame_index / 50`. Edit `episodes.csv` to remove
false positives or adjust confirmed intervals. Keep intervals sorted, merge
touching ranges, and retain valid frames at both ends of the recording.

```powershell
.\tools\repair\repair-video-flashes.ps1 -AnalysisDirectory '.\repairs\analysis' -OutputFile '.\repairs\repaired.mkv'
```

The source is not modified. The tool checks source identity and refuses an
existing output. `-PrepareOnly` writes the filter and command manifest without
encoding. Use a short extracted source and a separate analysis directory to
evaluate the result before processing a long recording.

Each selected interval is replaced with the last valid image. This causes a
brief freeze but retains the original timeline. Missing motion cannot be
recovered. Video is re-encoded to H.264 at CRF 18; `-Preset superfast` is the
default and `veryfast` is available. Original audio packets and their timestamps
are copied. Ordinary finalisation remains a separate stream-copy operation.

## Validate the output

Check playback at repaired passages and audio/video synchronization. Compare
duration, first timestamps and decoded frame counts with the source. Decode the
whole output to catch errors, and compare audio packet payloads and timestamps
when exact audio preservation matters.

For an image-level check, extract the repaired video to 64x48 gray rawvideo with
`-fps_mode passthrough`, then call `FlashRepairAnalysis.VerifyRepair` with the
original analysis dump, repaired dump and reviewed episode CSV. It compares every
frame to its intended source image; compression introduces small differences.
This verifies application of the chosen intervals, not their editorial accuracy.

The detector includes synthetic checks for continuous motion, a lasting scene
cut and injected stale frames:

```powershell
Add-Type -Path '.\tools\repair\FlashRepairAnalysis.cs'
[FlashRepairAnalysis]::SelfTest()
```

Keep recordings, case descriptions, reports, hashes and screenshots in a local
work/archive directory. The repository should contain reusable code and this
guide, not evidence from individual recordings.
