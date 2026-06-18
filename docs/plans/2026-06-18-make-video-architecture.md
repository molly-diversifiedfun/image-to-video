# make-video — Architecture & Process Design

**Status:** Approved design (2026-06-18). Source for the five feature PRDs in `docs/prds/`.

## 1. Purpose

Extend the existing `make-video` (still-image → long silent video) into a single tool that builds long-form ambient videos from any media input, with optional audio and seamless transitions. One command, one thing for a non-technical operator to learn.

## 2. Design principle: route by input, compose shared engines

The five features are surface variations of one job: **fill a target duration with media, optionally add audio, hide every seam.** The tool auto-detects the input and dispatches to a mode; every mode is assembled from the same small set of engines.

```
INPUT (auto-detected)              MODE          PRD
──────────────────────────────────────────────────────
1 image                          → still         PRD-5 (+ existing)
folder of images  (--sequence)   → slideshow     PRD-1
1 video clip                     → loop-extend    PRD-2, PRD-3
folder of video clips            → mix           PRD-4
```

`--audio PATH` overlays on any mode. Detection: image vs video by extension; file vs folder by `-d`.

## 3. Shared engines

| Engine | Responsibility | Used by |
|--------|----------------|---------|
| `encode-still` | image → single-keyframe segment (encode once) | still, slideshow |
| `seamless-loop` | build ONE self-seamless unit (tail crossfades into head), encode once, then concat-copy to fill duration | loop-extend |
| `xfade-join` | crossfade two segments — video `xfade` + audio `acrossfade` | slideshow, mix |
| `clip-sequencer` | order a clip set (shuffle, no adjacent repeat, reshuffle each pass) and trim the last junction to hit the exact target length | mix |
| `audio-build` | assemble an audio track to the target length — single file → seamless loop; folder → crossfaded playlist — then mux | all modes with `--audio` |

### 3.1 The seam-cost insight (why some modes are fast and one is slow)

A crossfade is a *re-encode* of the overlap region. The cost of a mode is the number of **unique** seams it must encode:

- **loop-extend**: the clip loops against *itself*, so there is exactly ONE unique seam (tail→head). Encode that seam-blended loop unit once, then byte-copy it N times. Fast.
- **slideshow**: N images → N−1 unique seams, each a ~2–3s dissolve. Few, short. Fast.
- **mix**: every adjacent pair of *different* clips is a unique seam, and the whole timeline is one continuous `xfade` chain → full re-encode. Slow (GPU-accelerated, ~1–2h for a multi-hour file). This is inherent, not a defect.

## 4. Canonical pipeline (every mode follows this SOP shape)

```
1. INTAKE      parse input path + duration + flags; classify input type
2. VALIDATE    inputs exist, are readable media, duration > 0, audio decodable
3. PLAN        compute target seconds, segment count, seam count, est. time/size; log it
4. BUILD       run the mode's engine(s) to produce the silent video timeline
5. AUDIO       if --audio: audio-build to target length, mux (no re-encode of video)
6. FINALIZE    +faststart, write output next to source (or --out)
7. VERIFY      probe duration (±0.5s), stream presence, seam frame-diff sample
```

Each PRD's "SOP" section instantiates these seven steps for that mode.

## 5. Cross-cutting requirements

- **Output**: H.264 MP4, 30 fps, 4K-native (downscale flag available), `yuv420p`, `+faststart`.
- **Audio**: AAC, stereo, normalized to a consistent loudness target; absent → silent (back-compatible).
- **Crossfade defaults**: video dissolve 1.5s (loops/clips), 2.5s (slideshow images); audio crossfade matched. All overridable via `--xfade SECONDS`.
- **Parallelism**: auto by mode (copy-bound modes high; re-encode modes low, GPU shared). `--jobs` overrides.
- **Hygiene**: skip non-media and macOS `._` files; spaces in paths safe; bundled ffmpeg on Apple Silicon.
- **Determinism**: `--seed N` makes shuffle reproducible (mix mode).

## 6. Risks

| Risk | Mitigation |
|------|------------|
| Mix mode render time surprises the user | PLAN step prints estimate + requires nothing; document clearly |
| Audio loudness mismatch across a playlist | normalize each track to a shared LUFS target in `audio-build` |
| Crossfade still faintly visible on high-contrast cuts | tunable `--xfade`; default longer for slideshow |
| Variable clip resolutions/fps in a mix folder | normalize all clips to the project resolution/fps before xfade |
| Exact target length with crossfades (overlaps shorten total) | `clip-sequencer` trims the final junction to land on the exact second |

## 7. Out of scope (v1)

Titles/captions, color grading, per-clip effects, beat-synced cuts, vertical/Shorts formatting, non-macOS builds. Revisit after the five core modes ship.
