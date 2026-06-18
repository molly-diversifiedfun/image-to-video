# HANDOFF — make-video build (audio + transitions)

**Date:** 2026-06-18
**Branch:** `feat/audio-and-transitions` (pushed to origin through `67988ae`)
**Milestones:** PRD-5 (photo + audio) AND PRD-2 (seamless loop-extend) COMPLETE + real-smoked. 98/98 tests.
**Method:** subagent-driven development (implementer → spec review → code-quality review → fix loop), per `docs/plans/2026-06-18-make-video-implementation.md`.

## Goal
Extend the existing bash `make-video` (still→long silent video) into a unified, input-routed tool with audio + seam-checked transitions, per the 5 PRDs in `docs/prds/`. Runtime is **bash + bundled ffmpeg only** (friend's Mac has no Python/Homebrew — zero-install is a hard constraint). Dev tests use `bats` + `ffprobe`/PSNR/RMS.

## Done (Phase 0–1 core + start of Phase 2)
- **Task 0** — bats harness: `tests/helpers/fixtures.sh` (`mk_image/mk_clip/mk_audio`, `$FFMPEG`/`$FFPROBE` resolution), `tests/helpers/assert.sh` (`assert_duration/assert_has_stream/assert_seam_ok`). Review caught a Critical: seam check silently passed on ffmpeg error — fixed.
- **Tasks 1+2** — `lib/classify.sh::classify_input` (image|video|image-dir|video-dir|unknown), `lib/duration.sh::parse_duration` (hours→secs, validated).
- **Task 3** — `lib/mux.sh::mux_audio VIDEO AUDIO OUT` — `-c:v copy` (proven), AAC `-b:a 192k`, audio REPLACE via explicit `-map`. CALLER CONTRACT: AUDIO must be pre-fit to video length (`-shortest` truncates otherwise).
- **Task 4** — `lib/audio.sh::audio_build SRC TARGET_SECS OUT` (single-file branch): trims if long, click-free `acrossfade` self-seamless loop if short, `loudnorm` I=-16. Dir branch is a stub returning non-zero. Review caught TWO real bugs: (1) seam test was toothless (peak-over-200ms can't see a click) → rewritten to RMS-delta in a 1ms window WITH a negative-control test that proves a hard loop FAILS; (2) sample-rate hardcoded 44100 broke 48 kHz sources → now queries actual sample rate.

- **Task 5** — `lib/audio.sh` folder branch: `audio_build DIR …` → crossfaded, per-track-loudness-normalized playlist (sorted or `--shuffle --seed N`), looped to fill, exact duration. Teeth-tested (40 LUFS raw disparity would fail; per-track loudnorm → 0.92 LUFS).
- **PRD-5 (Tasks 7–8)** — `--audio PATH` wired into `make-video` still mode (single file → loop; folder → playlist). Video stream stays `-c:v copy` (static path) or muxes onto the zoom re-encode. No-`--audio` path is byte-for-byte unchanged (regression-tested). Real-smoked on the actual 4K fine-art TIFF + audio → h264+aac, exact duration. Temp-dir cleanup guaranteed on all exit paths (RETURN traps don't fire under `set -e` script-exit, so explicit `|| { cleanup; return 1; }`).

- **`loop_unit`** (`lib/loop.sh`) — builds ONE loop unit per `--loop pingpong|crossfade|native`, encode-once. Honesty-verified: pingpong truly seamless (boundary ≈ baseline), crossfade hides flash only (+13 dB over hard cut, NOT seamless), native = as-is.
- **`seam_check`** (`lib/seam.sh`) — runtime reporter: boundary-vs-baseline PSNR → SEAMLESS/SOFT/VISIBLE; teeth-tested (hard cut → VISIBLE); rejects FRAME<12 (degenerate-baseline false-pass guard).
- **PRD-2 (loop-extend mode)** — single video clip → `loop_unit` → concat-copy `-t` to ~exact target (Δ<0.1s real) → PREVIEW GATE (`seam_check` at the real wrap frame via `nb_read_packets`, prints verdict + emits a seam-preview clip; recommends pingpong only when verdict≠SEAMLESS AND not already pingpong; never hangs in non-TTY/`--yes`). Native audio looped through the unit; `--audio` replaces. `--zoom` rejected for video. Temp cleanup on all exit paths.

All committed; `bats tests/` = **98/98 green**. Run: `export PATH="/opt/homebrew/bin:$PATH"; bats tests/`.

## Key decisions / lessons
- **Seam strategy is evidence-based** (red-team, architecture §3.2): crossfade hides the flash but leaves a content jump (28.6 dB); pingpong is truly seamless (≈baseline) but reverses motion; loop-native source is the third option. `--loop {crossfade|pingpong|native}`.
- **Tests must have teeth**: two separate review rounds caught tests that passed on broken code (Task 0 seam helper; Task 4 seam test). Every seam/quality test now needs a negative control proving it fails on the bad case.
- PRD-4 (multi-clip mixer) is gated to ship LAST (slow full re-encode).

## Remaining (resume here)
Phases 0–3 DONE: shared core + PRD-5 (photo+audio) + PRD-2 (seamless loop-extend). 2 of 5 features shipped.
- **PRD-3** (clip + soundtrack) — THIN: it's PRD-2's loop-extend video + the `--audio` path already wired (file→loop, folder→playlist), with audio REPLACE as the default for clips (drone hum unwanted) and `--keep-native` to layer. Mostly a default-flip + a couple tests. Likely the next quick win.
- **PRD-1** (slideshow) — new `xfade_join` engine: chain per-image still segments (each held N hours) with crossfades into ONE video; `--each`, `--shuffle`; few seams so fast.
- **PRD-4** (multi-clip mixer) — LAST: `clip_sequencer` (shuffle, no adjacent repeat, `--seed`) + normalize-to-project + `xfade_join` chain (full GPU re-encode, slow) + mandatory preview + `--hardcut` fast fallback.

NOTE: not yet merged to `main`; drive copy at `/Volumes/1TB SSD/ImageToVideo/` still has the OLD silent-only tool — re-sync (lib/ + new make-video) when ready to hand off.

## Resume instructions
1. `cd ~/github/ImageToVideo && git checkout feat/audio-and-transitions && git pull`
2. `export PATH="/opt/homebrew/bin:$PATH" && bats tests/` → expect 53/53.
3. Continue subagent-driven from Task 5 (full text in `docs/plans/2026-06-18-make-video-implementation.md`). Keep the two-stage review + negative-control discipline.
4. The deployed tool + bundled ffmpeg live on the friend's drive at `/Volumes/1TB SSD/ImageToVideo/` (binaries gitignored; reproduce with `setup-mac-arm64.sh`). Re-sync the drive copy after the feature lands.
