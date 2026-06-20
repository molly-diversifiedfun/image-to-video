# image-to-video

Turn a still image into a long **silent** video — any length, from one image or a whole folder. Built for ambient screens, gallery displays, and YouTube.

The trick that makes it fast: a static image only needs **one keyframe for the whole video**. The tool encodes a short segment once, then concat-copies it (no re-encoding) to fill the duration — so a 3-hour 4K file is ready in **~90 seconds**, not hours.

## Requirements

- macOS, **Apple Silicon** (M1–M5)
- ffmpeg + ffprobe — `brew install ffmpeg` (see [Setup](#setup)); no other dependencies

## Setup

```bash
brew install ffmpeg       # recommended — installs ffmpeg + ffprobe on your PATH
```

The tool finds ffmpeg/ffprobe automatically: it prefers a copy bundled in `bin/`, then falls back to whatever is on your `PATH` (so a Homebrew install just works).

**No Homebrew?** Two portable alternatives that need no system install:
- `./setup-mac-arm64.sh` — downloads + checksum-verifies static ffmpeg/ffprobe into `bin/` (good for running self-contained off a USB/SSD).
- Or drop your own static `ffmpeg`/`ffprobe` binaries into `bin/`.

## Usage

```bash
# One image → 3-hour video
./make-video photo.tiff 3

# A whole folder → every image becomes its own 3-hour video (parallel)
./make-video /path/to/images 3

# A short video clip → stretched to 8h with a truly-seamless loop
./make-video clip.mov 8 --loop pingpong

# An 8h rain loop: smooth 5s dissolve, fade from/to black, 1080p, exact filename
./make-video rain.mov 8 --xfade 5 --fade 3 --height 1080 --out rain-8h.mp4

# A folder of images → ONE long video, each image holds then dissolves into the next
./make-video ./images --slideshow --each 1 --out slideshow.mp4

# A folder of CLIPS, mixed, encoded fast on Apple Silicon
./make-video ./clips --mix 4 --gpu --out mixed.mp4

# A folder of CLIPS → ONE long video, shuffled with crossfades to fill a target length
./make-video ./clips --mix 4 --out mixed.mp4              # 4 hours, default 1.5s crossfades
./make-video ./clips --mix 4 --audio ./songs/ --out mixed.mp4   # + crossfaded music playlist

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
| `--audio PATH` | Add a soundtrack. A **file** loops seamlessly; a **folder** becomes a crossfaded, loudness-matched playlist. Fills the full length; video stream stays copied. On a **video clip**, the music **replaces** the clip's native sound by default. |
| `--keep-native` | Layer the `--audio` music **over** a video clip's native sound instead of replacing it (mixed via `amix`). Requires `--audio`; ignored if the clip has no audio track. |
| `--slideshow` | Turn a **folder of images** into ONE long video: each image holds, then crossfades into the next. Requires a directory input + `--out FILE`. Without it, a folder is batched (one video per image). |
| `--each HOURS` | Slideshow: per-image hold time (alias for the positional `HOURS`). Total length = (images × each) − (n−1)×xfade. |
| `--shuffle` | Slideshow: randomize image order (`--seed N` for a repeatable shuffle). Default order is sorted by filename. |
| `--fill` | Slideshow/mix: crop mixed-aspect inputs to fill the frame instead of letterboxing (the default fits + pads). |
| `--mix` | Turn a **folder of video clips** into ONE long video: clips are sequenced to fill the target `HOURS`, every junction a crossfade, **no clip back-to-back with itself**, reshuffled each pass. Normalizes mixed sources to one resolution/fps. **Re-encodes** (slow mode) — prints a size/time estimate, renders a short preview, and asks go/no-go before the full render. Requires a directory + a target `HOURS` + `--out FILE`. |
| `--order MODE` | Mix: `shuffle` (default; seeded, even exposure) or `name` (sorted, deterministic). |
| `--seed N` | Repeatable shuffle (slideshow + mix). |
| `--clip-secs N` | Mix: cap each clip to N seconds (default: whole clip). |
| `--hardcut` | Mix: concat clips with **no** crossfade — a fast preview/fallback that skips the re-encode. |
| **(seamless is the default)** | Loop-extend is **perfectly seamless by default**: the video dissolve defaults to **5s** (auto-clamped on short clips), the audio crossfade is **auto-detected** from the clip's ambience (raising the dissolve to it if needed), and the whole loop is **re-encoded continuously** — removing the per-loop keyframe pulse (1-frame video flicker) and the per-loop AAC boundary (faint audio blip) that plain concat-copy leaves. CPU `libx264` (the GPU re-keyframes the seam). Scales with output length. |
| `--fast` | Loop-extend: **opt out** of the seamless pass — fast, length-independent concat-copy (the old default), which leaves a faint per-loop seam. For quick drafts. |
| `--smooth` | No-op alias (seamless is already the default). Kept so older commands still work. |
| `--detect-xfade` | Loop-extend: **report** the auto-detected audio crossfade length for a clip and exit (no render). `make-video CLIP --detect-xfade`. Same detector the default seamless path uses. |
| `--loop MODE` | Video-clip looping: `pingpong` (truly seamless, but reverses motion — unusable for rain/falling motion), `crossfade` (default; the clip's tail dissolves into its head **across the loop seam**, so it flows continuously with no flash and no backward jump — the right choice when the source can't be reversed), `native` (source already loops). |
| `--xfade SECS` | Crossfade/seam duration (loop-extend default 1.0s; slideshow 2.5s; mix 1.5s). For loop-extend, a longer window (e.g. `--xfade 5`) makes the dissolve smoother; the clip must be ≥ 3× the window (a 5s dissolve needs a ≥15s clip). An oversized window on a short clip is **clamped to the largest that fits** (with a note) rather than erroring. |
| `--fade SECS` | Fade up from black at the start and down to black at the end — **video AND audio**, `SECS` each. The top-and-tail polish for ambient/sleep loops. Re-encodes only the two ends and stream-copies the middle, so a multi-hour file stays fast. Works in loop-extend, still, and mix. |
| `--crf N` | Encode quality, 0–51 (lower = better/larger). Applies across modes; loop-extend keeps its own default of 23 unless `--crf` is given. |
| `--height N` | Downscale output to N px tall (keep aspect, even width). The biggest lever on a multi-hour file's size — e.g. `--height 1080` on a 4K source is ~4× smaller. |
| `--gpu` | **Mix mode:** encode on Apple Silicon **VideoToolbox** (`h264_videotoolbox`) instead of CPU libx264 — much faster on the re-encode-heavy mix. Falls back to CPU with a note if unavailable. Loop-extend is already copy-based (length-independent), so it needs no GPU. |
| `--yes` | Skip the seam/preview go/no-go gate and render immediately (loop-extend + mix; for scripts/batch). |
| `--zoom N` | Add a slow continuous zoom of N% over a **photo**. **Re-encodes every frame** (GPU/VideoToolbox), so it's slow: a 3h file takes ~1.5–2h instead of ~90s. |
| `--out DIR \| FILE` | Write to `DIR` (named after the source) **or** to an exact `FILE` (e.g. `--out rain-8h.mp4`, parent dir auto-created). `--out FILE` works in every mode. |
| `--jobs N` | Concurrency. Omit it — auto-picked by mode. |
| `--static` | Force the fast no-zoom path (the default for photos). |
| `-h`, `--help` | Full usage. |

Loop-extend and mix print the actual **wall-clock render time** (`rendered in Ns`) on completion; mix also prints an up-front size/time estimate and which encoder (CPU/GPU) it will use.

**Loop-extend** prints a seam-quality verdict (`SEAMLESS` / `SOFT` / `VISIBLE`) and a short preview clip before the full render, and recommends `--loop pingpong` when the seam isn't truly seamless. With the seam-spanning crossfade construction, `crossfade` now reports `SEAMLESS` on most content. It never blocks in a non-TTY/`--yes` context.

**Mix** is the only mode that fully re-encodes (every junction is a unique seam). It prints an estimated size/render-time, renders a short preview of the first few junctions with a seam-check, and asks go/no-go before committing to the multi-hour render. The body of each clip between seams is built once and concat-copied, so render cost scales with the number of *unique* clips/seams, not total length. Same `--yes`/non-TTY auto-proceed rule.

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
