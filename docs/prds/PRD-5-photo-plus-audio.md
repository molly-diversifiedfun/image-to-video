# PRD-5 — Photo + audio (still image → long video with a soundtrack)

**Mode:** `still` + `--audio` · **Feature:** "2-hour video from a photo, add audio" · **Speed:** fast

## 1. Problem

The existing still-image tool makes a long *silent* video. Operators also want a soundtrack on it — a single looped track or a playlist — without any other change to the fast still pipeline.

## 2. Users

- **Operator:** drops one photo + a duration + an audio file/folder.
- **Viewer:** sees a single image for hours with a continuous music bed.

## 3. Use cases

- **UC-1:** 1 photo → 2h, one ambient track looped seamlessly.
- **UC-2:** 1 photo → 2h, a folder of songs as a crossfaded playlist looped to length.
- **UC-3:** 1 photo → 2h with `--zoom 4` AND audio (subtle motion + music bed).

## 4. Functional requirements

- FR-1: Accept one image + target duration + `--audio PATH`.
- FR-2: Video: existing `still` pipeline (encode-once + concat-copy), or `--zoom N` for the continuous-zoom variant.
- FR-3: Audio per shared model: file → seamless loop to length; folder → crossfaded, loudness-normalized playlist looped to length.
- FR-4: Mux audio without re-encoding the video stream (audio is added, video copied).
- FR-5: Back-compatible: no `--audio` → silent output exactly as today.
- FR-6: Output per project spec; next to source or `--out`.

## 5. SOP (operational steps)

1. **INTAKE** — image, target hours, `--audio`, `--zoom`.
2. **VALIDATE** — image decodes; audio path exists/decodes; duration > 0.
3. **PLAN** — still vs zoom path; audio single-loop vs playlist; print est. size/time.
4. **BUILD** — `encode-still` → concat-copy to length (or zoom re-encode if `--zoom`).
5. **AUDIO** — `audio-build` to target length; mux (video copied, audio AAC).
6. **FINALIZE** — `+faststart`, write output.
7. **VERIFY** — duration ±0.5s; video + audio streams present; audio fills full length with no early end or seam click.

## 6. Acceptance criteria

- A 2h photo+audio output (no zoom) renders in ~minutes; video stream is the fast copy path, only audio is added.
- Single-file audio loops seamlessly; multi-song audio crossfades with no gaps.
- Omitting `--audio` produces the identical silent file as the current tool (no regression).

## 7. Risks / open questions

- Combining `--zoom` (slow re-encode) with audio — audio cost is trivial; total time dominated by the zoom re-encode (documented in the still/zoom PRD).
- Audio longer than target → trim with a short fade-out; shorter single file → loop. Both handled by `audio-build`.
