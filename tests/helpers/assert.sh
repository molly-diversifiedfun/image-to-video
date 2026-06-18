#!/usr/bin/env bash
#
# tests/helpers/assert.sh — assertion helpers for bats tests.
#
# Usage: source this file from a bats test via:
#   load "$REPO_ROOT/tests/helpers/assert.sh"
#
# This file assumes fixtures.sh has already been loaded so $FFMPEG/$FFPROBE
# are available.

# ---------------------------------------------------------------------------
# assert_duration FILE SECS TOL
#
# Fails if the container duration of FILE differs from SECS by more than TOL.
# Uses ffprobe's format-level duration (reliable for .mp4 with a moov atom).
# ---------------------------------------------------------------------------
assert_duration() {
  local file="${1:?assert_duration: FILE required}"
  local expected="${2:?assert_duration: SECS required}"
  local tol="${3:?assert_duration: TOL required}"

  [[ -f "$file" ]] || { echo "assert_duration: file not found: $file" >&2; return 1; }

  local actual
  actual="$("$FFPROBE" \
    -v error \
    -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 \
    "$file")"

  # Guard: if ffprobe returned empty or non-numeric, fail loudly rather than
  # silently treating the duration as 0 and producing confusing comparisons.
  [[ "$actual" =~ ^[0-9] ]] || {
    echo "assert_duration: non-numeric duration from ffprobe ('${actual}') for $file" >&2
    return 1
  }

  # Use awk for floating-point comparison (bash only does integers)
  local ok
  ok="$(awk -v a="$actual" -v e="$expected" -v t="$tol" 'BEGIN {
    diff = a - e
    if (diff < 0) diff = -diff
    print (diff <= t) ? "ok" : "fail"
  }')"

  if [[ "$ok" != "ok" ]]; then
    echo "assert_duration: expected ${expected}s ± ${tol}s, got ${actual}s (file: $file)" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# assert_has_stream FILE KIND
#
# Fails if FILE does not contain a stream of type KIND.
#   KIND — "a" for audio, "v" for video
# ---------------------------------------------------------------------------
assert_has_stream() {
  local file="${1:?assert_has_stream: FILE required}"
  local kind="${2:?assert_has_stream: KIND required}"

  [[ -f "$file" ]] || { echo "assert_has_stream: file not found: $file" >&2; return 1; }

  local selector
  case "$kind" in
    a) selector="a" ;;
    v) selector="v" ;;
    *) echo "assert_has_stream: KIND must be 'a' or 'v', got: $kind" >&2; return 1 ;;
  esac

  # Use grep -c rather than wc -l: wc -l can count 1 on an empty trailing
  # newline. grep -c counts only lines with at least one character, and exits
  # non-zero on no match (which we suppress with || true to avoid set -e traps).
  local count
  count="$("$FFPROBE" \
    -v error \
    -select_streams "$selector" \
    -show_entries stream=index \
    -of csv=p=0 \
    "$file" | grep -c .)" || true
  count="${count:-0}"

  if [[ "$count" -lt 1 ]]; then
    echo "assert_has_stream: no ${kind} stream found in $file" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# __assert_seam_psnr_pair FILE FRAME_A FRAME_B
#
# Internal helper — NOT for direct use outside assert.sh.
# Named with __ prefix to avoid collisions with other helper files.
#
# Computes PSNR between two specific frames of FILE (by 0-based frame number).
# Prints a single numeric value (dB) or 999 (for "inf") to stdout.
#
# Fails loudly (return 1 + stderr message) if ffmpeg produces no output,
# which indicates an encoding/seeking error rather than a low-PSNR result.
# Silently returning 0 on error would make the seam check falsely pass.
# ---------------------------------------------------------------------------
__assert_seam_psnr_pair() {
  local file="$1"
  local frame_a="$2"
  local frame_b="$3"

  # Select frame_a from input 0 and frame_b from input 1, compare with psnr.
  # psnr=stats_file=- writes the stats line to stdout; without it the PSNR
  # data only appears in ffmpeg's log stream, which would be suppressed here.
  local psnr_line
  psnr_line="$("$FFMPEG" \
    -nostdin -loglevel error \
    -i "$file" \
    -i "$file" \
    -lavfi "[0:v]select='between(n,${frame_a},${frame_a})',setpts=PTS-STARTPTS[a]; \
            [1:v]select='between(n,${frame_b},${frame_b})',setpts=PTS-STARTPTS[b]; \
            [a][b]psnr=stats_file=-" \
    -f null - 2>/dev/null)"

  # If the output is empty, ffmpeg failed (bad seek, missing frames, etc.).
  # Silently returning 0 would make the seam check falsely pass — fail loudly.
  if [[ -z "$psnr_line" ]]; then
    echo "__assert_seam_psnr_pair: no PSNR output from ffmpeg" \
         "(frames ${frame_a}->${frame_b} in $file) — possible ffmpeg error" >&2
    return 1
  fi

  # Extract psnr_avg from the stats line; map "inf" to 999 for numeric compare.
  local result
  result="$(echo "$psnr_line" | awk '{
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^psnr_avg:/) {
        val = substr($i, 10)
        if (val == "inf") print 999
        else print val
        exit
      }
    }
    # If the token was not found, the stats line format changed — signal error.
    print "PARSE_ERROR"
  }')"

  if [[ "$result" == "PARSE_ERROR" ]]; then
    echo "__assert_seam_psnr_pair: could not parse psnr_avg from: ${psnr_line}" >&2
    return 1
  fi

  echo "$result"
}

# ---------------------------------------------------------------------------
# assert_seam_ok FILE FRAME
#
# Detects visible seams at frame boundaries by comparing PSNR.
#
# Approach:
#   1. Extract frames (FRAME-1, FRAME) from the boundary being tested.
#   2. Extract a mid-clip "baseline" pair of consecutive frames well away from
#      any boundary, where we know the image is stable.
#   3. Compute PSNR for each pair using ffmpeg's psnr filter (stats_file=-).
#   4. PASS if boundary PSNR >= (baseline PSNR - THRESHOLD_DB).
#      A seam typically causes a PSNR drop of 10–20 dB or more; this threshold
#      is intentionally generous (8 dB) to avoid false positives on clips with
#      gradual motion while still catching hard cuts and flash frames.
#
# FRAME is 0-indexed.  The file must have at least (FRAME + 2) frames.
#
# Requires: $FFMPEG, $FFPROBE set by fixtures.sh
# ---------------------------------------------------------------------------
assert_seam_ok() {
  local file="${1:?assert_seam_ok: FILE required}"
  local frame="${2:?assert_seam_ok: FRAME required}"

  # Threshold: boundary PSNR must be no more than 8 dB below the baseline.
  # Rationale: mid-clip consecutive frames in a smooth gradient source typically
  # score 35–65 dB; a hard cut drops to ~10–15 dB.  8 dB gives headroom for
  # gradual motion blur while still catching hard cuts.
  local threshold_db=8

  [[ -f "$file" ]] || { echo "assert_seam_ok: file not found: $file" >&2; return 1; }

  local total_frames
  total_frames="$("$FFPROBE" -v error \
    -select_streams v:0 \
    -count_packets \
    -show_entries stream=nb_read_packets \
    -of default=noprint_wrappers=1:nokey=1 \
    "$file")"

  # Guard: nb_read_packets can return "N/A" for some containers, which makes
  # the arithmetic below throw an error. Fail early with a clear diagnostic.
  [[ "$total_frames" =~ ^[0-9]+$ ]] || {
    echo "assert_seam_ok: could not determine frame count for $file" \
         "(ffprobe returned '${total_frames}')" >&2
    return 1
  }

  # Boundary: (FRAME-1, FRAME)
  local boundary_a=$(( frame - 1 ))
  [[ $boundary_a -ge 0 ]] || boundary_a=0
  local boundary_b=$(( boundary_a + 1 ))

  # Baseline: two consecutive frames from just BEFORE the boundary window.
  # Sampling near the boundary (rather than at the midpoint or first quarter)
  # ensures the baseline reflects the same local motion regime, making the
  # relative comparison robust against clips with variable per-frame PSNR.
  # Use boundary_a-10 as the anchor (or the earliest available frames).
  local baseline_a=$(( boundary_a - 10 ))
  [[ $baseline_a -ge 0 ]] || baseline_a=0
  local baseline_b=$(( baseline_a + 1 ))

  local baseline_psnr boundary_psnr
  baseline_psnr="$(__assert_seam_psnr_pair "$file" "$baseline_a" "$baseline_b")" || return 1
  boundary_psnr="$(__assert_seam_psnr_pair "$file" "$boundary_a" "$boundary_b")" || return 1

  # PASS if boundary_psnr >= baseline_psnr - threshold_db
  local ok
  ok="$(awk -v bp="$boundary_psnr" -v base="$baseline_psnr" -v t="$threshold_db" 'BEGIN {
    print (bp >= base - t) ? "ok" : "fail"
  }')"

  if [[ "$ok" != "ok" ]]; then
    echo "assert_seam_ok: seam detected at frame ${frame}:" \
         "boundary PSNR=${boundary_psnr} dB, baseline PSNR=${baseline_psnr} dB," \
         "threshold=${threshold_db} dB (file: $file)" >&2
    return 1
  fi
}
