# PRD-2 — Seamless loop-extend (short ambient clip → hours, invisible seam)

**Mode:** `loop-extend` · **Feature:** "1-min ambient clip → 8h, crossfade so seamless the eye can't catch the loop, audio too" · **Speed:** fast

> **Red-team correction (2026-06-18):** "seamless" is not free on arbitrary footage. Measured boundary PSNR (baseline ≈48 dB): a **crossfade** loop leaves a visible content jump (**28.6 dB**) — it hides the *flash*, not the content reset; **pingpong** is truly seamless (**48–56 dB**) but reverses motion. See architecture §3.2. This PRD now specifies `--loop` strategies and a preview gate instead of promising blanket invisibility.

## 1. Problem

A short ambient clip (with natural sound) must be extended to many hours by looping — but the loop point should be as undetectable as the footage allows, in both video and audio. A hard loop "pops." The honest constraint: truly invisible looping requires either symmetric/loop-ready footage or motion-reversing pingpong; a plain crossfade only suppresses the flash.

## 2. Users

- **Operator:** drops one clip + a duration, gets a multi-hour file that looks/sounds continuous.
- **Viewer:** cannot tell where the clip ends and restarts.

## 3. Use cases

- **UC-1:** 60s water clip → 8h, `--loop pingpong`, truly seamless, natural sound preserved.
- **UC-2:** 60s abstract/fog clip → 8h, `--loop crossfade` (default), flash hidden; content reset acceptable on textural footage.
- **UC-3:** 90s forward-moving drone → operator wants no reversal AND no jump → tool's preview flags the crossfade jump; resolution is loop-native source or accept pingpong (documented, not magic).
- **UC-4:** Clip shorter than ~3× xfade → reject with a clear message.

## 4. Functional requirements

- FR-1: Accept one video clip + target duration (hours, fractional ok).
- FR-2: `--loop {crossfade|pingpong|native}` (default `crossfade`) builds the loop unit per architecture §3.2. Encode the unit ONCE, then concat-copy to fill the duration (fast; length-independent).
- FR-3: Apply the matching treatment to the clip's **own audio** at the seam (`acrossfade` for crossfade/native; reverse-concat for pingpong) — no audio pop.
- FR-4: `seam-check` the loop boundary and report boundary-vs-baseline PSNR; if the drop is large, WARN and recommend `pingpong` or loop-native source.
- FR-5: PREVIEW gate — before the full render, emit the loop unit + a ~10s clip spanning the seam for the operator to eyeball; require go/no-go (architecture §4).
- FR-6: Preserve the clip's native audio by default; `--audio` may replace or layer per the shared model.
- FR-7: `--xfade SECONDS` (default 1.5s); validate clip length ≥ 3×xfade.
- FR-8: Output matches project spec; written next to source or `--out`.

## 5. SOP (operational steps)

1. **INTAKE** — clip path, target hours, `--xfade`.
2. **VALIDATE** — clip decodes (video+audio); length ≥ 3×xfade; duration > 0.
3. **PLAN** — loop-unit length = clip − xfade; loops = ceil(target / unit); print seam length, loop count, est. size.
4. **BUILD** —
   a. PREVIEW: `loop-unit` builds the unit per `--loop`; `seam-check` measures the boundary; emit the unit + a ~10s seam clip; show PSNR + estimate; get go/no-go.
   b. FULL: concat-copy the unit to reach the target; trim the tail to the exact second.
5. **AUDIO** — if `--audio` supplied: `audio-build` and mux per chosen layer/replace behavior; else keep native track.
6. **FINALIZE** — `+faststart`, write output.
7. **VERIFY** — duration ±0.5s; `seam-check` boundary PSNR vs baseline (WARN on sharp drop); audio continuity at the seam.

## 6. Acceptance criteria

- An 8h output from a 60s clip renders in minutes (unit encoded once, rest copied).
- `--loop pingpong` produces a boundary PSNR within ~baseline (seamless); `--loop crossfade` suppresses the flash and the preview honestly shows any residual content jump.
- The operator sees a seam preview and an estimate before any multi-hour render starts.
- Native ambient sound is present and continuous end-to-end (no pop at the join).

## 7. Risks / open questions

- **Directional motion can't be made both seamless AND forward-playing by crossfade** (proven: 28.6 dB jump). Resolution is `pingpong` (reverses) or loop-native source — surfaced to the operator, not hidden.
- Pingpong doubles the unit length and reverses motion — odd for some content; it's an explicit choice, not the default.
- Audio with a hard transient near the boundary — raise `--xfade`; surfaced by `seam-check`/VERIFY.
