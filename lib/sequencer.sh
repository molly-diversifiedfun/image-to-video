#!/usr/bin/env bash
#
# lib/sequencer.sh — sequence_clips: order a folder of clips into one long
# timeline that fills a target duration (PRD-4 multi-clip mixer).
#
# CONTRACT
# ────────
#   sequence_clips TARGET_SECS XFADE SEED MODE  < (key<TAB>dur lines)
#
#   Reads "key<TAB>duration_secs" lines on stdin (one per source clip) and
#   prints the ordered keys — one per line, repeats allowed — whose timeline
#   reaches TARGET_SECS.  The first field is an OPAQUE key echoed back verbatim:
#   callers may pass clip paths OR integer indices (mix_clips feeds indices and
#   maps them back to its own arrays).  Where:
#
#     timeline(count) = Σ dur_i − (count − 1) · XFADE
#
#   (every junction overlaps by XFADE seconds, so each clip after the first
#   contributes dur − XFADE to the running length).
#
#   MODE:
#     shuffle (default) — each pass is a fresh seeded permutation of all clips;
#                         no clip is ever adjacent to itself; reshuffled every
#                         pass for roughly even exposure across a long video.
#     name              — identity order, cycled (deterministic, no shuffle).
#
#   SEED makes shuffle reproducible (awk srand). Pure logic — no ffmpeg, no I/O
#   beyond stdin/stdout.
#
#   Minimal fill: emission stops as soon as the timeline reaches the target, so
#   dropping the last emitted clip would undershoot it.
#
#   Exits non-zero if no clips are supplied.

sequence_clips() {
  local target="${1:?sequence_clips: TARGET_SECS required}"
  local xfade="${2:-0}"
  local seed="${3:-1}"
  local mode="${4:-shuffle}"

  awk -F'\t' \
    -v target="$target" -v xfade="$xfade" -v seed="$seed" -v mode="$mode" '
    { path[NR] = $1; dur[NR] = $2; n = NR }
    END {
      if (n < 1) { exit 1 }
      srand(seed)
      cum = 0; count = 0; last = ""
      while (cum < target) {
        # Build this pass: a permutation of 1..n (identity for name mode).
        for (i = 1; i <= n; i++) ord[i] = i
        if (mode != "name") {
          for (i = n; i >= 2; i--) {       # seeded Fisher-Yates
            j = int(rand() * i) + 1
            t = ord[i]; ord[i] = ord[j]; ord[j] = t
          }
        }
        # Avoid an adjacent repeat across the pass boundary: if this pass would
        # open with the same clip the previous pass closed on, swap it forward.
        if (n >= 2 && last != "" && path[ord[1]] == last) {
          t = ord[1]; ord[1] = ord[2]; ord[2] = t
        }
        for (i = 1; i <= n; i++) {
          p = ord[i]
          print path[p]
          if (count == 0) cum = dur[p]
          else            cum = cum + dur[p] - xfade
          count++
          last = path[p]
          if (cum >= target) break
        }
      }
    }
  '
}
