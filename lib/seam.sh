#!/usr/bin/env bash
#
# lib/seam.sh — seam_check VIDEO FRAME [--json]
#
# RUNTIME reporter for the preview gate.  Tells an operator how visible a
# loop boundary is by measuring PSNR at the boundary vs a local baseline.
#
# USAGE
# ─────
#   seam_check VIDEO FRAME [--json]
#
#   VIDEO  — path to the video file to inspect
#   FRAME  — 1-based frame index of the boundary (first frame AFTER the cut)
#   --json — emit a JSON object instead of the human-readable line
#
# MEASUREMENT
# ───────────
#   boundary_psnr : PSNR between frame (FRAME-1) and frame FRAME
#   baseline_psnr : PSNR between the pair ~10 frames BEFORE the boundary
#                   (frames FRAME-11 and FRAME-10, clamped to 0 if needed)
#   drop          : baseline_psnr - boundary_psnr
#
#   Empty PSNR output from ffmpeg is a measurement failure — we NEVER silently
#   return 0.  The caller must receive a non-zero exit so the preview gate can
#   surface the error instead of falsely approving an unmeasured seam.
#
# VERDICTS
# ────────
#   drop <= 8 dB       → SEAMLESS  (e.g. pingpong strategy)
#   8 < drop <= 18 dB  → SOFT      (e.g. crossfade: flash hidden, content jump)
#   drop > 18 dB       → VISIBLE   (hard cut / obvious jump)
#
# OUTPUT
# ──────
#   human (default):
#     seam@<frame>: boundary=NN.N dB baseline=NN.N dB drop=NN.N dB -> VERDICT
#
#   --json:
#     {"frame":F,"boundary":NN.N,"baseline":NN.N,"drop":NN.N,"verdict":"VERDICT"}
#
# RETURN CODES
# ────────────
#   0  — successful measurement (verdict in stdout; may be any verdict)
#   1  — measurement failure (missing file, no video stream, bad frame,
#         empty PSNR output, or non-integer FRAME)
#
# DEPENDENCIES
# ────────────
#   $FFMPEG and $FFPROBE must be set by the caller (fixtures.sh or make-video).
#   Targets bash 3.2+.  Uses awk for float arithmetic.

# ---------------------------------------------------------------------------
# _seam_psnr_pair VIDEO FRAME_A FRAME_B
#
# Compute PSNR between two frames (0-based indices) of VIDEO.
# Prints the numeric dB value to stdout (maps "inf" → 999).
# Returns 1 and emits a diagnostic to stderr on any measurement failure.
# NEVER silently passes empty PSNR output — this exact silent-pass bug
# bit us previously and cost debugging time.
# ---------------------------------------------------------------------------
_seam_psnr_pair() {
  local video="$1"
  local frame_a="$2"
  local frame_b="$3"

  local psnr_line
  psnr_line="$("$FFMPEG" \
    -nostdin -loglevel error \
    -i "$video" \
    -i "$video" \
    -lavfi "[0:v]select='between(n,${frame_a},${frame_a})',setpts=PTS-STARTPTS[a]; \
            [1:v]select='between(n,${frame_b},${frame_b})',setpts=PTS-STARTPTS[b]; \
            [a][b]psnr=stats_file=-" \
    -f null - 2>/dev/null)"

  # Empty output = ffmpeg error (bad seek, frame beyond clip, missing stream, etc.)
  # Fail loudly — never silently pass.
  if [[ -z "$psnr_line" ]]; then
    echo "seam_check: no PSNR output from ffmpeg (frames ${frame_a}->${frame_b} in $video) — possible bad frame index or ffmpeg error" >&2
    return 1
  fi

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
    print "PARSE_ERROR"
  }')"

  if [[ "$result" == "PARSE_ERROR" ]]; then
    echo "seam_check: could not parse psnr_avg from ffmpeg output: ${psnr_line}" >&2
    return 1
  fi

  echo "$result"
}

# ---------------------------------------------------------------------------
# seam_check VIDEO FRAME [--json]
# ---------------------------------------------------------------------------
seam_check() {
  local video="${1:?seam_check: VIDEO required}"
  local frame="${2:?seam_check: FRAME required}"
  local output_json=0

  # Parse optional --json flag (remaining args after VIDEO and FRAME)
  shift 2
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) output_json=1; shift ;;
      *)
        echo "seam_check: unknown option: $1" >&2
        return 1
        ;;
    esac
  done

  # ------------------------------------------------------------------
  # Validate VIDEO exists
  # ------------------------------------------------------------------
  if [[ ! -f "$video" ]]; then
    echo "seam_check: VIDEO not found: $video" >&2
    return 1
  fi

  # ------------------------------------------------------------------
  # Validate VIDEO has a video stream
  # ------------------------------------------------------------------
  local video_count
  video_count="$("$FFPROBE" -v error \
    -select_streams v \
    -show_entries stream=index \
    -of csv=p=0 \
    "$video" | grep -c .)" || true
  video_count="${video_count:-0}"

  if [[ "$video_count" -lt 1 ]]; then
    echo "seam_check: VIDEO has no video stream: $video" >&2
    return 1
  fi

  # ------------------------------------------------------------------
  # Validate FRAME is a positive integer >= 1
  # ------------------------------------------------------------------
  if [[ ! "$frame" =~ ^[0-9]+$ ]] || [[ "$frame" -lt 1 ]]; then
    echo "seam_check: FRAME must be a positive integer >= 1, got: $frame" >&2
    return 1
  fi

  # ------------------------------------------------------------------
  # Guard: require sufficient lead-in for a distinct local baseline.
  #
  # Baseline pair = (frame-11, frame-10); boundary pair = (frame-1, frame).
  # When FRAME < 12, baseline_a = frame-1-10 clamps to 0, making the
  # baseline pair (0,1) — identical to the boundary pair when FRAME=1.
  # drop = 0 in that case, so the verdict is always SEAMLESS regardless
  # of the actual content.  That false SEAMLESS would fool the preview gate.
  #
  # Minimum FRAME = 12 guarantees baseline_a = frame-11 >= 1, keeping the
  # baseline pair strictly before and non-overlapping with the boundary.
  # ------------------------------------------------------------------
  if [[ "$frame" -lt 12 ]]; then
    echo "seam_check: FRAME=${frame} is too close to the clip start to measure a distinct baseline (minimum FRAME=12)" >&2
    return 1
  fi

  # ------------------------------------------------------------------
  # Compute 0-based frame indices
  #
  # boundary pair : (frame-1, frame)   [0-based: (frame-1, frame)]
  # baseline pair : (frame-11, frame-10) — always distinct from boundary
  # ------------------------------------------------------------------
  local boundary_a=$(( frame - 1 ))
  local boundary_b=$(( frame ))

  # Baseline anchor: 10 frames before boundary_a.
  # The FRAME >= 12 guard above ensures baseline_a >= 1, so no clamping needed.
  local baseline_a=$(( boundary_a - 10 ))
  local baseline_b=$(( baseline_a + 1 ))

  # ------------------------------------------------------------------
  # Measure PSNR for both pairs
  # Fail loudly if either measurement fails (no silent pass).
  # ------------------------------------------------------------------
  local boundary_psnr baseline_psnr
  if ! boundary_psnr="$(_seam_psnr_pair "$video" "$boundary_a" "$boundary_b")"; then
    return 1
  fi
  if ! baseline_psnr="$(_seam_psnr_pair "$video" "$baseline_a" "$baseline_b")"; then
    return 1
  fi

  # ------------------------------------------------------------------
  # Compute drop and determine verdict
  # ------------------------------------------------------------------
  local drop verdict
  drop="$(awk -v base="$baseline_psnr" -v bnd="$boundary_psnr" 'BEGIN {
    d = base - bnd
    if (d < 0) d = 0
    printf "%.1f", d
  }')"

  verdict="$(awk -v d="$drop" 'BEGIN {
    if (d <= 8)       print "SEAMLESS"
    else if (d <= 18) print "SOFT"
    else              print "VISIBLE"
  }')"

  # ------------------------------------------------------------------
  # Emit output
  # ------------------------------------------------------------------
  if [[ "$output_json" -eq 1 ]]; then
    # Round values to 1 decimal for JSON
    local b_fmt base_fmt drop_fmt
    b_fmt="$(printf "%.1f" "$boundary_psnr")"
    base_fmt="$(printf "%.1f" "$baseline_psnr")"
    drop_fmt="$drop"
    echo "{\"frame\":${frame},\"boundary\":${b_fmt},\"baseline\":${base_fmt},\"drop\":${drop_fmt},\"verdict\":\"${verdict}\"}"
  else
    local b_fmt base_fmt
    b_fmt="$(printf "%.1f" "$boundary_psnr")"
    base_fmt="$(printf "%.1f" "$baseline_psnr")"
    echo "seam@${frame}: boundary=${b_fmt} dB baseline=${base_fmt} dB drop=${drop} dB -> ${verdict}"
  fi
}
