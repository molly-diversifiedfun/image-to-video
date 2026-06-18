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

  local count
  count="$("$FFPROBE" \
    -v error \
    -select_streams "$selector" \
    -show_entries stream=index \
    -of csv=p=0 \
    "$file" | wc -l | tr -d ' ')"

  if [[ "$count" -lt 1 ]]; then
    echo "assert_has_stream: no ${kind} stream found in $file" >&2
    return 1
  fi
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
#   3. Compute PSNR for each pair using ffmpeg's built-in psnr filter.
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
  # score 35–50 dB; a hard cut drops to ~20 dB.  8 dB gives plenty of headroom.
  local threshold_db=8

  [[ -f "$file" ]] || { echo "assert_seam_ok: file not found: $file" >&2; return 1; }

  local fps
  fps="$("$FFPROBE" -v error \
    -select_streams v:0 \
    -show_entries stream=r_frame_rate \
    -of default=noprint_wrappers=1:nokey=1 \
    "$file" | awk -F'/' '{ if ($2+0>0) printf "%.6f", $1/$2; else print $1 }')"

  local total_frames
  total_frames="$("$FFPROBE" -v error \
    -select_streams v:0 \
    -count_packets \
    -show_entries stream=nb_read_packets \
    -of default=noprint_wrappers=1:nokey=1 \
    "$file")"

  # Baseline: two consecutive frames near the middle of the clip (away from edges)
  local mid_frame
  mid_frame=$(( total_frames / 2 ))
  local baseline_start=$(( mid_frame - 1 ))
  [[ $baseline_start -ge 0 ]] || baseline_start=0

  # Boundary frames: (FRAME-1, FRAME)
  local boundary_start=$(( frame - 1 ))
  [[ $boundary_start -ge 0 ]] || boundary_start=0

  # Helper: compute PSNR between two consecutive frames starting at START_FRAME
  # Returns the average PSNR value (or "inf" which we treat as very high).
  _psnr_pair() {
    local f="$1"
    local start_frame="$2"
    local fps_val="$3"

    local start_ts
    start_ts="$(awk -v s="$start_frame" -v r="$fps_val" 'BEGIN { printf "%.6f", s/r }')"

    # Grab exactly 2 frames from start_ts, compare them with psnr filter.
    # psnr outputs a line like: psnr_avg:NN.NN ...
    local psnr_line
    psnr_line="$("$FFMPEG" \
      -nostdin -loglevel error \
      -ss "$start_ts" -i "$f" \
      -ss "$start_ts" -i "$f" \
      -frames:v 2 \
      -lavfi "[0:v]trim=start_frame=0:end_frame=1,setpts=PTS-STARTPTS[a]; \
              [1:v]trim=start_frame=1:end_frame=2,setpts=PTS-STARTPTS[b]; \
              [a][b]psnr" \
      -f null - 2>&1 | grep 'psnr_avg' | tail -1)"

    # Extract numeric value; "inf" maps to a large number (999)
    echo "$psnr_line" | awk '{
      for (i=1; i<=NF; i++) {
        if ($i ~ /^psnr_avg:/) {
          val = substr($i, 10)
          if (val == "inf") print 999
          else print val
          exit
        }
      }
      print 0
    }'
  }

  local baseline_psnr boundary_psnr
  baseline_psnr="$(_psnr_pair "$file" "$baseline_start" "$fps")"
  boundary_psnr="$(_psnr_pair "$file" "$boundary_start" "$fps")"

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
