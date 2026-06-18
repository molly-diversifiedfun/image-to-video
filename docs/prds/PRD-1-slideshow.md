# PRD-1 — Slideshow (images → one long crossfaded video)

**Mode:** `slideshow` · **Feature:** "10 images → 10-hour video, 1 hour each" · **Speed:** fast

## 1. Problem

A folder of stills should become a single long video where each image holds the screen for a set time and dissolves gently into the next — one file, gallery-like, no hard cuts.

## 2. Users

- **Operator (friend):** drops a folder + a per-image duration, gets one MP4.
- **Viewer:** sees a calm rotating set of images on an ambient display.

## 3. Use cases

- **UC-1:** 10 images, 1 hour each → one 10-hour video with a soft dissolve at each hour mark.
- **UC-2:** 6 images, 30 min each, with background audio → one 3-hour video with a music bed.
- **UC-3:** 1 image in the folder → degenerates to `still` mode (no transitions).

## 4. Functional requirements

- FR-1: Accept a folder of images + a per-image duration (`--each HOURS`, default applies to all).
- FR-2: Produce ONE combined video; total length = (image count × per-image duration) minus crossfade overlaps, reported precisely.
- FR-3: Crossfade between consecutive images (default 2.5s dissolve, `--xfade`).
- FR-4: Images ordered by sorted filename (operator controls order by naming); `--shuffle` optional.
- FR-5: Optional `--audio` per the shared audio model.
- FR-6: Skip non-images and `._` files; handle mixed resolutions by normalizing to the project resolution.
- FR-7: Default output 4K/30fps silent unless `--audio`; written next to the folder or `--out`.

## 5. SOP (operational steps)

1. **INTAKE** — read folder, per-image duration, flags.
2. **VALIDATE** — ≥1 image present; each decodes; duration > 0.
3. **PLAN** — order list; compute total = Σ durations − (n−1)×xfade; print count, total, est. time/size.
4. **BUILD** —
   a. `encode-still` each image to a segment of its hold duration (encode-once trick, parallel).
   b. `xfade-join` the segments in order into one timeline (only the n−1 short dissolves re-encode).
5. **AUDIO** — if `--audio`: `audio-build` to total length, mux.
6. **FINALIZE** — `+faststart`, write output.
7. **VERIFY** — duration within ±0.5s; one video stream (+audio if requested); sample a dissolve boundary.

## 6. Acceptance criteria

- A 10-image / 1-hour-each run yields a single ~10h MP4 with visible-but-soft dissolves and no hard cuts.
- Total duration matches the reported figure within ±0.5s.
- Render time is dominated by the per-image still encodes, not by length (dissolves are few).
- With `--audio`, audio fills the full length with no abrupt end.

## 7. Risks / open questions

- Mixed aspect ratios → letterbox vs crop? **Default:** fit within frame, pad to project aspect; `--fill` to crop.
- Very large image counts (100+) → many segments; still fast, but PLAN should warn on extreme counts.
