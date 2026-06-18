# PRD-3 — Clip + soundtrack (extend one clip, add music)

**Mode:** `loop-extend` + `--audio` · **Feature:** "1-min+ drone clip → a few hours, add one looped ambient track OR many songs" · **Speed:** fast

## 1. Problem

A short clip (e.g. drone footage) should be extended to a few hours and given a soundtrack — either a single ambient track looped, or a set of songs played as a seamless playlist. This is PRD-2's seamless loop plus the shared audio engine, called out separately because the *intent* (music-driven, not natural-sound-driven) differs.

## 2. Users

- **Operator:** drops a clip + a target length + an audio file or an audio folder.
- **Viewer:** sees extended footage with a continuous music bed.

## 3. Use cases

- **UC-1:** 90s drone clip → 3h, one ambient track looped seamlessly under it.
- **UC-2:** Same clip → 4h, a folder of 12 songs as a crossfaded playlist that loops to fill the time.
- **UC-3:** Operator pre-mixed a single long audio file → tool just trims/loops it to length, no playlist logic.

## 4. Functional requirements

- FR-1: Accept one clip + target duration + `--audio PATH`.
- FR-2: Video: seamless loop-extend (per PRD-2 engine).
- FR-3: Audio source resolution (shared model): `--audio` is a **file** → loop it to length with a soft seam; a **folder** → crossfaded playlist (sorted or `--shuffle`), looped to length.
- FR-4: Default behavior with `--audio` here is **replace** the clip's native sound with the music (drone hum often unwanted); `--keep-native` to layer instead.
- FR-5: Loudness-normalize the music bed to a consistent target.
- FR-6: `--xfade` applies to both the video loop seam and audio crossfades.
- FR-7: Output per project spec.

## 5. SOP (operational steps)

1. **INTAKE** — clip, target hours, `--audio PATH`, audio flags.
2. **VALIDATE** — clip decodes; audio path exists and decodes (every file in a folder); duration > 0.
3. **PLAN** — video loop plan (PRD-2) + audio plan (single-loop vs playlist, track count); print both.
4. **BUILD** — `seamless-loop` the video to target (silent or native held aside).
5. **AUDIO** — `audio-build`: file → seamless loop to length; folder → `xfade-join` audio tracks into a crossfaded, loudness-normalized playlist, looped to length; then mux (replace by default).
6. **FINALIZE** — `+faststart`, write output.
7. **VERIFY** — duration ±0.5s; audio present full-length, no gap at playlist joins or loop wrap; loudness within target band.

## 6. Acceptance criteria

- A few-hour output renders fast (video seam once + audio assembly).
- Single-file audio loops with no audible seam; multi-song audio crossfades between tracks with no gap or click.
- Music plays continuously to the exact end; no early silence.

## 7. Risks / open questions

- Songs of very different loudness/genre in one folder — normalization helps; ordering matters (`--shuffle` vs sorted).
- Licensing of supplied music is the operator's responsibility (note in docs).
- If the operator wants music to *start* at a specific track, sorted order + naming is the lever.
