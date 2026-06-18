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
| `loop-unit` | build ONE loop unit per the chosen `--loop` strategy (see §3.2), encode once, then concat-copy to fill duration | loop-extend |
| `xfade-join` | crossfade two segments — video `xfade` + audio `acrossfade` | slideshow, mix |
| `clip-sequencer` | order a clip set (shuffle, no adjacent repeat, reshuffle each pass) and trim the last junction to hit the exact target length | mix |
| `audio-build` | assemble an audio track to the target length — single file → seamless loop; folder → crossfaded playlist, loudness-normalized — then mux | all modes with `--audio` |
| `seam-check` | measure boundary PSNR vs the clip's baseline adjacent-frame PSNR; warn if a seam drops sharply (auto-QC for a non-technical operator) | loop-extend, slideshow, mix |

### 3.1 The seam-cost insight (why some modes are fast and one is slow)

A crossfade is a *re-encode* of the overlap region. The cost of a mode is the number of **unique** seams it must encode:

- **loop-extend**: the clip loops against *itself*, so there is exactly ONE unique seam. Encode that loop unit once, then byte-copy it N times. Fast.
- **slideshow**: N images → N−1 unique seams, each a ~2–3s dissolve. Few, short. Fast.
- **mix**: every adjacent pair of *different* clips is a unique seam, and the whole timeline is one continuous `xfade` chain → full re-encode. Slow (GPU-accelerated, ~1–2h for a multi-hour file). This is inherent, not a defect.

### 3.2 Seam strategy — what "seamless" actually means (tested 2026-06-18)

A red-team measured boundary PSNR (higher = less visible) on smooth ambient-like content, baseline adjacent-frame PSNR ≈ 48 dB:

| `--loop` strategy | boundary | reverses motion? | use for |
|---|---|---|---|
| `crossfade` (default) | **28.6 dB** — visible content jump | no | abstract/textural footage where a content reset reads as "fine" |
| `pingpong` | **48–56 dB** — provably seamless | **yes** | symmetric ambient (water, fire, fog, clouds); the only truly invisible option for arbitrary footage |
| `native` | seamless IF source loops | no | footage shot/edited to loop (end frame ≈ start frame) |

**Consequence for the PRDs:** "seamless" is NOT free on arbitrary footage. Crossfade hides a hard cut's *flash* but leaves a ~`xfade`-length content jump — fine for water/fog, visibly wrong for a forward-moving drone shot. True invisibility requires `pingpong` (accepting motion reversal) or loop-native source. The tool must (a) expose `--loop`, (b) default to `crossfade` but recommend `pingpong` for motion, (c) state the source-footage requirement, and (d) run `seam-check` + a preview so the operator sees the seam before committing to a multi-hour render.

## 4. Canonical pipeline (every mode follows this SOP shape)

```
1. INTAKE      parse input path + duration + flags; classify input type
2. VALIDATE    inputs exist, are readable media, duration > 0, audio decodable
3. PLAN        compute target seconds, segment/seam count, est. time/size; log it.
               If est. render time > PREVIEW_THRESHOLD (default 5 min), require
               a preview pass (step 4a) before the full render.
4. BUILD       (a) PREVIEW: build the loop unit / first+seam segments + a short
                   clip around each seam; run seam-check; show the operator the
                   seam preview + estimate and get an explicit go/no-go.
               (b) FULL: produce the full silent video timeline.
5. AUDIO       if --audio: audio-build to target length, mux (no re-encode of video)
6. FINALIZE    +faststart, write output next to source (or --out)
7. VERIFY      probe duration (±0.5s), stream presence; seam-check each boundary
               and WARN if any boundary PSNR drops sharply vs baseline; for audio,
               check loudness continuity across playlist/loop joins
```

Each PRD's "SOP" section instantiates these steps for that mode. The PREVIEW gate (3→4a) is the answer to "a non-technical operator can't tell a subtly-broken multi-hour output from a good one" — the seam is shown and auto-checked on a 10-second artifact before 1–2 hours are spent.

## 5. Cross-cutting requirements

- **Output**: H.264 MP4, 30 fps, 4K-native (downscale flag available), `yuv420p`, `+faststart`.
- **Audio**: AAC, stereo, normalized to a consistent loudness target; absent → silent (back-compatible).
- **Crossfade defaults**: video dissolve 1.5s (loops/clips), 2.5s (slideshow images); audio crossfade matched. All overridable via `--xfade SECONDS`.
- **Loop strategy** (`--loop`): `crossfade` (default) | `pingpong` (truly seamless, reverses motion) | `native` (loop-ready source). See §3.2.
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

## 7. Build phasing (red-team finding #3: gate the slow/fragile mode)

Ship in fast-win, risk-ascending order. Each phase is usable on its own.

1. **Shared core + `audio-build`** — engines every mode needs; validate on the simplest mode.
2. **PRD-5 (photo + audio)** — smallest delta over today's tool; proves the audio path.
3. **PRD-2 (loop-extend) + `loop-unit` + `seam-check` + preview gate** — proves the seam strategy and QC loop on real footage. **This phase must validate §3.2 on the operator's actual clips before proceeding.**
4. **PRD-3 (clip + soundtrack)** — PRD-2 video path + audio model; thin.
5. **PRD-1 (slideshow)** — `xfade-join` on stills; few seams.
6. **PRD-4 (multi-clip mixer)** — last: slowest, most input-heterogeneity, carries the most risk for the least-asked capability. Do not start until 1–5 are proven.

## 8. Out of scope (v1)

Titles/captions, color grading, per-clip effects, beat-synced cuts, vertical/Shorts formatting, non-macOS builds. Revisit after the five core modes ship.
