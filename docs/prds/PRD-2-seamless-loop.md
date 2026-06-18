# PRD-2 — Seamless loop-extend (short ambient clip → hours, invisible seam)

**Mode:** `loop-extend` · **Feature:** "1-min ambient clip → 8h, crossfade so seamless the eye can't catch the loop, audio too" · **Speed:** fast

## 1. Problem

A short ambient clip (with natural sound) must be extended to many hours by looping — but the loop point must be undetectable to both eye and ear. A hard loop "pops"; the join must be a delicate crossfade in video AND audio.

## 2. Users

- **Operator:** drops one clip + a duration, gets a multi-hour file that looks/sounds continuous.
- **Viewer:** cannot tell where the clip ends and restarts.

## 3. Use cases

- **UC-1:** 60s forest clip → 8h, ~1.5s video+audio crossfade at the seam, natural sound preserved.
- **UC-2:** Same, but `--xfade 3` for an even softer blend on a high-motion clip.
- **UC-3:** Clip shorter than the crossfade length → reject with a clear message (clip must be ≥ ~3× xfade).

## 4. Functional requirements

- FR-1: Accept one video clip + target duration (hours, fractional ok).
- FR-2: Build a **self-seamless loop unit**: the clip's tail crossfades into its own head so that, when repeated, end→start is continuous.
- FR-3: Apply the same crossfade to the clip's **own audio** (the natural ambient sound) at the seam — no audio pop.
- FR-4: Encode the seam-blended loop unit ONCE, then concat-copy to fill the duration (fast; length-independent).
- FR-5: Preserve the clip's native audio by default; `--audio` may replace or layer per the shared model.
- FR-6: `--xfade SECONDS` (default 1.5s); validate clip length ≥ 3×xfade.
- FR-7: Output matches project spec; written next to source or `--out`.

## 5. SOP (operational steps)

1. **INTAKE** — clip path, target hours, `--xfade`.
2. **VALIDATE** — clip decodes (video+audio); length ≥ 3×xfade; duration > 0.
3. **PLAN** — loop-unit length = clip − xfade; loops = ceil(target / unit); print seam length, loop count, est. size.
4. **BUILD** —
   a. `seamless-loop`: produce the unit where tail (last *d*s) dissolves into head (first *d*s), video + audio together; encode once.
   b. concat-copy the unit to reach the target; trim the tail to the exact second.
5. **AUDIO** — if `--audio` supplied: `audio-build` and mux per chosen layer/replace behavior; else keep native track.
6. **FINALIZE** — `+faststart`, write output.
7. **VERIFY** — duration ±0.5s; sample frames + audio at a seam: frame-diff and audio-RMS continuity below threshold (no pop).

## 6. Acceptance criteria

- An 8h output from a 60s clip renders in minutes (seam encoded once, rest copied).
- At any loop boundary, a frame-diff sample shows a smooth dissolve, not a cut; audio shows no discontinuity.
- Native ambient sound is present and continuous end-to-end.

## 7. Risks / open questions

- Clips that don't loop well (strong directional motion, a moving subject mid-frame) — crossfade hides the seam but motion may "rewind." **Note in docs**; longer `--xfade` helps; out of scope to motion-match.
- Audio with a hard transient near the boundary — crossfade duration may need raising; surfaced in VERIFY.
