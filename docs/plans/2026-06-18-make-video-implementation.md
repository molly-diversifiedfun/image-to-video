# make-video Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Extend the existing bash `make-video` into a unified, input-routed tool that builds long-form videos from images/clips with optional audio and seam-checked transitions, per the PRDs in `docs/prds/`.

**Architecture:** Single bash entrypoint that classifies input and dispatches to a mode; modes compose shared functions (`classify_input`, `audio_build`, `mux_audio`, `loop_unit`, `seam_check`, `xfade_join`, `clip_sequencer`). Runtime stays **bash + bundled ffmpeg** — the only zero-install option on the friend's Apple Silicon Mac (macOS ships no Python). Build in the risk-ascending phase order from architecture §7.

**Tech Stack:** bash, ffmpeg/ffprobe (bundled, arm64), `bats-core` for dev tests, ffprobe + PSNR for output assertions.

**Testing convention:** every engine function is a pure-ish bash function in a sourceable lib (`lib/*.sh`) so `bats` can call it directly; integration tests assert on real ffprobe output of tiny generated fixtures. Target: each new function has a unit test asserting its contract before wiring.

---

## Phase 0 — Test harness (prerequisite)

### Task 0: bats + fixtures

**Files:**
- Create: `lib/.gitkeep`, `tests/helpers/fixtures.sh`, `tests/helpers/assert.sh`, `tests/smoke.bats`
- Modify: `README.md` (dev-setup section)

**Step 1: Install bats (dev machine only).** Run: `brew install bats-core` (or vendor it). Expected: `bats --version` prints.
**Step 2: Write `tests/helpers/fixtures.sh`** — functions that generate tiny media with ffmpeg into a temp dir:
```bash
mk_image() { "$FFMPEG" -nostdin -loglevel error -y -f lavfi -i "color=c=$2:s=320x180" -frames:v 1 "$1"; }
mk_clip()  { "$FFMPEG" -nostdin -loglevel error -y -f lavfi -i "gradients=s=320x180:d=${3:-3}:speed=0.01" \
             -f lavfi -i "sine=frequency=${2:-220}:d=${3:-3}" -r 30 -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$1"; }
mk_audio() { "$FFMPEG" -nostdin -loglevel error -y -f lavfi -i "sine=frequency=$2:d=$3" -c:a aac "$1"; }
```
**Step 3: Write `tests/helpers/assert.sh`** — `assert_duration FILE SECS TOL`, `assert_has_stream FILE a|v`, `assert_seam_ok FILE FRAME` (PSNR boundary vs baseline).
**Step 4: Write `tests/smoke.bats`** — one test that generates a clip and asserts duration. Run: `bats tests/smoke.bats`. Expected: PASS.
**Step 5: Commit.** `git add -A && git commit -m "test: bats harness + ffmpeg fixtures"`

---

## Phase 1 — Shared core

### Task 1: `classify_input`

**Files:** Create `lib/classify.sh`; Test `tests/classify.bats`

**Step 1: Failing test** — assert `classify_input` returns `image|video|image-dir|video-dir|unknown`:
```bash
@test "single image -> image"   { source lib/classify.sh; run classify_input fix/a.png; [ "$output" = image ]; }
@test "folder of clips -> video-dir" { source lib/classify.sh; run classify_input fix/clips; [ "$output" = video-dir ]; }
```
**Step 2:** Run `bats tests/classify.bats` → FAIL (function undefined).
**Step 3:** Implement `classify_input PATH`: if dir, sample first media file's type → `image-dir`/`video-dir`; else extension → image/video; skip `._*`.
**Step 4:** Run → PASS.
**Step 5:** Commit `feat: input classifier`.

### Task 2: `parse_duration`

**Files:** Create `lib/duration.sh`; Test `tests/duration.bats`
- TDD: `parse_duration 3 → 10800`, `0.5 → 1800`, `0.0167 → 60` (round), `0 → error`. Implement with awk `printf "%d", h*3600+0.5`. Commit.

### Task 3: `mux_audio` (video-copy + AAC)

**Files:** Create `lib/mux.sh`; Test `tests/mux.bats`
- TDD: muxing an audio file onto a silent video yields a file with both streams, video stream **copied** (no re-encode), duration = video duration. Use `ffmpeg -i v -i a -map 0:v -map 1:a -c:v copy -c:a aac -shortest`. Assert via `assert_has_stream` + `assert_duration`. Commit.

### Task 4: `audio_build` — single file → seamless loop

**Files:** Create `lib/audio.sh`; Test `tests/audio_single.bats`
- TDD: given one short audio file + target secs, produce an audio file of exactly target secs that loops with a short `acrossfade` at the wrap (no click). Assert duration ±0.1s and that loudness is normalized (loudnorm). Technique: `aloop`/concat with `acrossfade` at the seam, then `atrim` to target, `loudnorm`. Commit.

### Task 5: `audio_build` — folder → crossfaded playlist

**Files:** Modify `lib/audio.sh`; Test `tests/audio_playlist.bats`
- TDD: given a folder of N short audio files + target secs, produce target-length audio where tracks `acrossfade` into each other (sorted or `--shuffle`), looping the playlist to fill, each track loudness-normalized to a shared LUFS. Assert duration ±0.1s and no gap at joins (RMS continuity). Commit.

### Task 6: `seam_check`

**Files:** Create `lib/seam.sh`; Test `tests/seam.bats`
- TDD: `seam_check FILE BOUNDARY_FRAME` returns baseline-adjacent PSNR and boundary PSNR; a hard-cut fixture reports a large drop, a pingpong fixture reports ~baseline. (Reuses the measured method: extract frames, `psnr` filter.) Assert the hard-cut case is flagged. Commit.

---

## Phase 2 — PRD-5 (photo + audio), the smallest real delta

### Task 7: wire `--audio` into still mode

**Files:** Modify `make-video` (still path + arg parsing); Test `tests/mode_still_audio.bats`
**Step 1: Failing test** — `make-video img.png 0.02 --audio song.m4a --out OUT` yields a ~72s file with video+audio, video stream copied.
**Step 2:** Run → FAIL.
**Step 3:** Add `--audio PATH` flag; after the existing concat-copy builds the silent video, call `audio_build` to target secs then `mux_audio`.
**Step 4:** Run → PASS. Also assert no-`--audio` path is byte-for-byte the old silent behavior (regression guard).
**Step 5:** Commit `feat: PRD-5 photo + audio`.

### Task 8: `--audio` with folder (playlist) + zoom coexist

**Files:** Test `tests/mode_still_audio_folder.bats`, `tests/mode_still_zoom_audio.bats`
- TDD: folder audio fills full length; `--zoom 4 --audio` produces both motion and audio (video re-encoded by zoom, audio muxed). Commit.

---

## Phase 3 — PRD-2 (loop-extend) + seam strategy  *(detail TBD after Phase 2)*

Outline (expand into bite-sized tasks once Phase 2 ships and we validate on the operator's real clips):
- `loop_unit --loop crossfade|pingpong|native`; encode-once + concat-copy.
- Wire `seam_check` + the **PREVIEW go/no-go gate** (architecture §4) — emit loop unit + 10s seam clip + PSNR, require confirm before full render.
- Audio: clip-native seam crossfade (or pingpong reverse-concat); `--audio` replace/layer.
- **Gate:** validate §3.2 numbers on real footage before Phase 4.

## Phase 4 — PRD-3 (clip + soundtrack)  *(outline)*
Thin: Phase 3 video + `audio_build` replace-by-default; `--keep-native` to layer.

## Phase 5 — PRD-1 (slideshow)  *(outline)*
`xfade_join` chain over per-image still segments; total = Σ − (n−1)·xfade; `--each`, `--shuffle`.

## Phase 6 — PRD-4 (multi-clip mixer)  *(outline, ships last)*
`clip_sequencer` (shuffle, no adjacent repeat, `--seed`); normalize clips to project res/fps; `xfade_join` chain (full GPU re-encode); mandatory preview + progress; `--hardcut` fast preview.

---

## Cross-cutting (apply in every task)
- Spaces-in-paths safe; skip `._*`; bundled ffmpeg via existing resolution.
- Each mode follows the 7-step SOP (INTAKE→VALIDATE→PLAN→[PREVIEW]→BUILD→AUDIO→FINALIZE→VERIFY).
- Frequent commits (one per task). Update `README.md` usage as flags land.
- After each phase: real smoke on actual sample media, not just bats fixtures.
