# image-to-video

Turn a still image into a long **silent** video — any length, from one image or a whole folder. Built for ambient screens, gallery displays, and YouTube.

The trick that makes it fast: a static image only needs **one keyframe for the whole video**. The tool encodes a short segment once, then concat-copies it (no re-encoding) to fill the duration — so a 3-hour 4K file is ready in **~90 seconds**, not hours.

## Requirements

- macOS, **Apple Silicon** (M1–M5)
- ffmpeg + ffprobe — fetched into `bin/` (see [Setup](#setup)); no other dependencies

## Setup

```bash
./setup-mac-arm64.sh      # downloads + checksum-verifies ffmpeg/ffprobe into bin/
```

Alternatives: `brew install ffmpeg`, or drop your own static `ffmpeg`/`ffprobe` into `bin/`. The script prefers `bin/`, then falls back to `PATH`.

## Usage

```bash
# One image → 3-hour video
./make-video photo.tiff 3

# A whole folder → every image becomes its own 3-hour video (parallel)
./make-video /path/to/images 3

# A short video clip → stretched to 8h with a truly-seamless loop
./make-video clip.mov 8 --loop pingpong

# Add a soundtrack to any of the above (file loops; folder = crossfaded playlist)
./make-video photo.tiff 2 --audio song.m4a
./make-video photo.tiff 2 --audio ./songs/

# Per-file durations from a CSV (path,hours)
./make-video --manifest jobs.csv
```

The tool auto-detects the input: a **photo** → still mode; a **video clip** → loop-extend mode (concat-copy a seamless loop unit to length, with a seam-quality preview before the full render); a **folder** → batch.

`HOURS` may be fractional: `0.5` = 30 min, `0.0167` ≈ 1 min (good for a quick test). Point at a **folder** instead of a file to batch the whole directory.

### Options

| Flag | Effect |
|------|--------|
| `--audio PATH` | Add a soundtrack. A **file** loops seamlessly; a **folder** becomes a crossfaded, loudness-matched playlist. Fills the full length; video stream stays copied. |
| `--loop MODE` | Video-clip looping: `pingpong` (truly seamless, reverses motion), `crossfade` (default; hides the flash, not fully seamless), `native` (source already loops). |
| `--xfade SECS` | Crossfade/seam duration (default 1.0s clips, used by `--loop crossfade`). |
| `--yes` | Skip the loop-extend seam preview and render immediately (for scripts/batch). |
| `--zoom N` | Add a slow continuous zoom of N% over a **photo**. **Re-encodes every frame** (GPU/VideoToolbox), so it's slow: a 3h file takes ~1.5–2h instead of ~90s. |
| `--out DIR` | Write `.mp4`s to `DIR` instead of next to the source. |
| `--jobs N` | Concurrency. Omit it — auto-picked by mode. |
| `--static` | Force the fast no-zoom path (the default for photos). |
| `-h`, `--help` | Full usage. |

**Loop-extend** prints a seam-quality verdict (`SEAMLESS` / `SOFT` / `VISIBLE`) and a short preview clip before the full render, and recommends `--loop pingpong` when the seam isn't truly seamless. It never blocks in a non-TTY/`--yes` context.

## Output

4K-native H.264 `.mp4`, 30 fps, `yuv420p`, even dimensions, `+faststart` — uploads straight to YouTube. Silent by default; AAC soundtrack when `--audio` is given. Static mode ≈ a few GB for 3h; `--zoom` at high quality ≈ ~34 GB for a 3h 4K file.

## Development / tests

Tests use [bats-core](https://github.com/bats-core/bats-core).

```bash
brew install bats-core      # one-time, dev machine only
bats tests/                 # run all tests
```

### Harness layout

```
tests/
  helpers/
    fixtures.sh   # mk_image / mk_clip / mk_audio — generate tiny media via ffmpeg
    assert.sh     # assert_duration / assert_has_stream / assert_seam_ok
  smoke.bats      # proves the harness works end-to-end
lib/              # sourceable bash function files (e.g. lib/audio.sh)
```

`fixtures.sh` mirrors the same ffmpeg resolution logic as the main script: prefers `./bin/ffmpeg` + `./bin/ffprobe` if present, falls back to PATH.

`assert_seam_ok FILE FRAME` extracts a boundary frame pair and a mid-clip baseline pair, computes PSNR for each, and fails only if the boundary PSNR drops more than 8 dB below baseline — enough to catch hard cuts and flash frames while tolerating smooth gradient motion.

## Behavior notes

- Skips non-images and macOS `._` AppleDouble junk automatically.
- Bundled-binary mode self-heals exec bits and quarantine on startup (for ExFAT drives / cross-machine use).
- `bin/ffmpeg` + `bin/ffprobe` are gitignored; reproduce them with `setup-mac-arm64.sh`.
