# PRD-4 — Multi-clip mixer (folder of clips → long mixed video + soundtrack)

**Mode:** `mix` · **Feature:** "drop a folder of 20-50 short clips → 2-8h with smooth transitions, plus 20-50 songs mixed, or my own single audio file" · **Speed:** slow (full re-encode)

## 1. Problem

Given a folder of many short clips, build a long video that shuffles them with smooth crossfades and never feels repetitive, with a soundtrack assembled from a folder of songs (or a single supplied audio file). The most complex mode: many unique transitions mean a full re-encode.

## 2. Users

- **Operator:** drops a clips folder + a target length + (optionally) a songs folder or one audio file.
- **Viewer:** sees a varied, continuously-transitioning ambient reel with a music bed.

## 3. Use cases

- **UC-1:** 30 clips → 4h, shuffled, 1.5s crossfades, no clip twice in a row, reshuffling each pass; + 20 songs as a crossfaded playlist.
- **UC-2:** 50 clips → 8h, + a single pre-made 8h audio file the operator made themselves.
- **UC-3:** 20 clips → 2h, `--seed 7` for a reproducible order.

## 4. Functional requirements

- FR-1: Accept a clips folder + target duration + optional `--audio` (file or folder).
- FR-2: Sequence clips: shuffle, **no adjacent repeats**, reshuffle each pass; fill to target; trim the final junction to the exact second. `--seed` for determinism; `--order name` for sorted.
- FR-3: Whole clips used as-is (no trimming) by default; `--clip-secs N` to cap each.
- FR-4: Crossfade every junction (video `xfade` + audio `acrossfade`), default 1.5s, `--xfade`.
- FR-5: Normalize all clips to project resolution/fps before joining (mixed sources expected).
- FR-6: Audio per shared model: clips' own audio crossfaded through the timeline by default; OR `--audio` file/folder replaces it (single loop / crossfaded playlist).
- FR-7: PLAN must print the render-time/size estimate and that this mode re-encodes. Because the estimate exceeds PREVIEW_THRESHOLD, the tool emits a short preview (first few junctions + `seam-check`) and requires explicit go/no-go before the multi-hour render; progress is reported during the full pass so it never looks hung.
- FR-8: This mode ships LAST (architecture §7) — not started until the four fast modes are proven.

## 5. SOP (operational steps)

1. **INTAKE** — clips folder, target hours, `--audio`, `--seed`, `--xfade`, `--clip-secs`, `--order`.
2. **VALIDATE** — ≥2 clips; each decodes; gather durations/resolutions; audio (if any) decodes; duration > 0.
3. **PLAN** — `clip-sequencer` builds the order list to fill target (minus overlap); print clip count, total junctions, est. render time (GPU) + size; state clearly it re-encodes.
4. **BUILD** —
   a. normalize each clip to project res/fps.
   b. `xfade-join` the ordered clips into one continuous timeline (GPU-encoded; this is the slow step).
5. **AUDIO** — clips' own audio carried through the xfade chain by default; if `--audio`: `audio-build` (file loop / playlist crossfade, normalized) and mux as replacement.
6. **FINALIZE** — `+faststart`, write output.
7. **VERIFY** — duration ±0.5s; no adjacent-repeat in the order log; sample several junctions for smooth dissolve; audio continuous.

## 6. Acceptance criteria

- A 30-clip / 4h run produces one continuous video, every junction a smooth crossfade, no clip back-to-back with itself, ending on the exact target second.
- `--seed` reproduces the identical order.
- Render time estimate printed up front is within ~25% of actual.
- Soundtrack (folder or single file) fills the full length with no gaps/clicks.

## 7. Risks / open questions

- **Render time** is the headline risk — many unique seams force full re-encode (~1–2h for multi-hour 4K on Apple Silicon GPU), which collides with the "this tool is instant" expectation set by the fast modes. Mitigation: PLAN estimate + mandatory preview + explicit go/no-go + live progress; `--hardcut` (concat-copy, no crossfade) as a fast preview/fallback.
- Wildly mismatched source fps/resolution → normalization cost + quality loss; document recommended uniform-ish inputs.
- Memory/temp footprint for very long timelines — stream through, avoid materializing the whole thing in RAM.
- Shuffle fairness across a long video (even clip distribution) — reshuffle-per-pass gives roughly even exposure; document.
