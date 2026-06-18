#!/usr/bin/env bash
#
# lib/loop.sh — loop_unit CLIP OUT [--loop STRATEGY] [--xfade SECS]
#
# Build ONE loop unit (encode once) from a video CLIP such that
# concat-copying the unit repeatedly produces a continuous loop.
#
# STRATEGY (default: crossfade)
# ─────────────────────────────
#   pingpong
#     OUT = CLIP forward + CLIP reversed (video reversed, audio reversed via
#     areverse).  Length ≈ 2× CLIP.  When concat-copied, BOTH the internal
#     turn AND the wrap boundary are TRULY seamless: the first frame of the
#     reversed segment equals the last frame of the forward segment, so
#     adjacent-frame PSNR at the boundary matches mid-clip baseline PSNR.
#
#   crossfade  (default)
#     OUT = a unit whose tail crossfades into its head using ffmpeg's xfade
#     video filter and acrossfade audio filter.  When concat-copied, the
#     hard-cut FLASH is eliminated and boundary PSNR is measurably higher
#     than a naive hard concat.
#
#     NOTE: a content jump remains for directional motion content because the
#     tail frames and head frames show different positions in the scene — only
#     the visual discontinuity (flash) is removed.  Do NOT assert seamlessness
#     for this strategy on directional motion.  It DOES improve on a raw hard
#     cut (measured ≈28–32 dB vs ≈12–18 dB on smooth gradient content).
#
#     CLIP must be at least 3× xfade duration.  Shorter clips are rejected
#     with a non-zero exit and a diagnostic message on stderr.
#
#   native
#     OUT = CLIP as-is (stream copy).  The caller asserts that the source
#     already loops (i.e. its last frame ≈ its first frame).  loop_unit does
#     not verify loop-ability; it only copies the container.
#
# AUDIO TREATMENT
# ───────────────
#   pingpong  — audio reversed with areverse filter
#   crossfade — audio crossfaded with acrossfade filter (same duration as xfade)
#   native    — audio stream copied unchanged
#
#   If CLIP has NO audio stream, the output is video-only (no error).
#
# VALIDATION
# ──────────
#   • CLIP must exist as a regular file.
#   • CLIP must contain at least one video stream (non-zero + stderr otherwise).
#   • crossfade: CLIP duration must be >= 3× xfade (non-zero + stderr otherwise).
#   • Quiet: -nostdin -loglevel error -y throughout.
#
# DEPENDENCIES
# ────────────
#   $FFMPEG and $FFPROBE must be set by the caller (fixtures.sh or make-video).
#   Targets bash 3.2+.  Uses awk for float arithmetic (no bc dependency).

# ---------------------------------------------------------------------------
# _loop_has_audio FILE
# Returns 0 if FILE has at least one audio stream, 1 otherwise.
# ---------------------------------------------------------------------------
_loop_has_audio() {
  local file="$1"
  local count
  count="$("$FFPROBE" -v error \
    -select_streams a \
    -show_entries stream=index \
    -of csv=p=0 \
    "$file" | grep -c .)" || true
  count="${count:-0}"
  [[ "$count" -ge 1 ]]
}

# ---------------------------------------------------------------------------
# _loop_get_duration FILE
# Echo the float duration of FILE in seconds.  Returns 1 on failure.
# ---------------------------------------------------------------------------
_loop_get_duration() {
  local file="$1"
  local dur
  dur="$("$FFPROBE" \
    -v error \
    -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 \
    "$file")"
  [[ "$dur" =~ ^[0-9] ]] || return 1
  echo "$dur"
}

# ---------------------------------------------------------------------------
# loop_unit CLIP OUT [--loop STRATEGY] [--xfade SECS]
# ---------------------------------------------------------------------------
loop_unit() {
  local clip="${1:?loop_unit: CLIP required}"
  local out="${2:?loop_unit: OUT required}"
  shift 2

  # Defaults
  local strategy="crossfade"
  local xfade="1.0"

  # Parse optional arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --loop)
        strategy="${2:?--loop requires a STRATEGY value}"
        shift 2
        ;;
      --xfade)
        xfade="${2:?--xfade requires a SECS value}"
        shift 2
        ;;
      *)
        echo "loop_unit: unknown option: $1" >&2
        return 1
        ;;
    esac
  done

  # ------------------------------------------------------------------
  # Validate CLIP exists
  # ------------------------------------------------------------------
  if [[ ! -f "$clip" ]]; then
    echo "loop_unit: CLIP not found: $clip" >&2
    return 1
  fi

  # ------------------------------------------------------------------
  # Validate CLIP has a video stream
  # ------------------------------------------------------------------
  local video_count
  video_count="$("$FFPROBE" -v error \
    -select_streams v \
    -show_entries stream=index \
    -of csv=p=0 \
    "$clip" | grep -c .)" || true
  video_count="${video_count:-0}"

  if [[ "$video_count" -lt 1 ]]; then
    echo "loop_unit: CLIP has no video stream: $clip" >&2
    return 1
  fi

  # Detect audio presence once; used in all three strategies
  local has_audio=0
  _loop_has_audio "$clip" && has_audio=1

  # ------------------------------------------------------------------
  # Dispatch to strategy
  # ------------------------------------------------------------------
  case "$strategy" in
    pingpong)  _loop_pingpong  "$clip" "$out" "$has_audio" ;;
    crossfade) _loop_crossfade "$clip" "$out" "$has_audio" "$xfade" ;;
    native)    _loop_native    "$clip" "$out" ;;
    *)
      echo "loop_unit: unknown strategy: $strategy (choose pingpong|crossfade|native)" >&2
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# _loop_pingpong CLIP OUT HAS_AUDIO
#
# Build OUT = CLIP forward + CLIP reversed.
# Video reversed with reverse filter; audio reversed with areverse.
# If HAS_AUDIO==0 the output is video-only.
#
# The reversed segment uses a temp file so we can stream-copy both halves
# into the final container via concat demuxer (no quality loss beyond the
# initial encode of the reversed clip).
# ---------------------------------------------------------------------------
_loop_pingpong() {
  local clip="$1"
  local out="$2"
  local has_audio="$3"

  local tmp_rev
  tmp_rev="$(mktemp -p "${WORK_DIR:-$(dirname "$out")}" rev.XXXXXX.mp4)"

  # Step 1: encode the reversed clip into a temp file
  if [[ "$has_audio" -eq 1 ]]; then
    # Reverse both video and audio
    "$FFMPEG" \
      -nostdin -loglevel error -y \
      -i "$clip" \
      -vf "reverse" \
      -af "areverse" \
      -c:v libx264 -preset ultrafast -crf 23 \
      -c:a aac -b:a 64k \
      -pix_fmt yuv420p \
      "$tmp_rev" || { rm -f "$tmp_rev"; echo "loop_unit: pingpong reverse encode failed" >&2; return 1; }
  else
    # Video only — no audio to reverse
    "$FFMPEG" \
      -nostdin -loglevel error -y \
      -i "$clip" \
      -vf "reverse" \
      -an \
      -c:v libx264 -preset ultrafast -crf 23 \
      -pix_fmt yuv420p \
      "$tmp_rev" || { rm -f "$tmp_rev"; echo "loop_unit: pingpong reverse encode failed" >&2; return 1; }
  fi

  # Step 2: concat forward + reversed via the concat demuxer (stream copy)
  local list
  list="$(mktemp -p "${WORK_DIR:-$(dirname "$out")}" concat.XXXXXX.txt)"
  echo "file '${clip}'" >> "$list"
  echo "file '${tmp_rev}'" >> "$list"

  if [[ "$has_audio" -eq 1 ]]; then
    "$FFMPEG" \
      -nostdin -loglevel error -y \
      -f concat -safe 0 -i "$list" \
      -c copy \
      "$out"
  else
    "$FFMPEG" \
      -nostdin -loglevel error -y \
      -f concat -safe 0 -i "$list" \
      -c:v copy \
      -an \
      "$out"
  fi
  local st=$?
  rm -f "$tmp_rev" "$list"
  return $st
}

# ---------------------------------------------------------------------------
# _loop_crossfade CLIP OUT HAS_AUDIO XFADE
#
# Build OUT = a unit whose tail crossfades into its head so that
# concat-copies have no hard-cut flash.
#
# Technique:
#   Let D = CLIP duration.  The crossfade window = XFADE seconds.
#   We encode OUT as a clip of duration (D - XFADE):
#     - Video: xfade filter transitions from the end of CLIP back to the
#       start of CLIP over XFADE seconds (offset = D - 2*XFADE so the
#       transition finishes at D - XFADE).
#     - Audio: acrossfade of tail and head.
#
#   When two copies of OUT are concat-copied, the head of the second copy
#   immediately follows the crossfaded tail of the first, so there is no
#   visible flash at the join point.  A content jump may still occur for
#   directional motion — this is documented and acceptable.
#
# Requirement: D >= 3 * XFADE (so the xfade offset is positive and the
# head/tail segments don't overlap into the body).
# ---------------------------------------------------------------------------
_loop_crossfade() {
  local clip="$1"
  local out="$2"
  local has_audio="$3"
  local xfade="$4"

  # Get clip duration
  local dur
  if ! dur="$(_loop_get_duration "$clip")"; then
    echo "loop_unit: could not read duration from CLIP: $clip" >&2
    return 1
  fi

  # Validate: D >= 3 * xfade
  local ok
  ok="$(awk -v d="$dur" -v x="$xfade" 'BEGIN { print (d >= 3*x) ? "ok" : "fail" }')"
  if [[ "$ok" != "ok" ]]; then
    echo "loop_unit: crossfade requires CLIP duration (${dur}s) >= 3 × xfade (${xfade}s = $(awk -v x="$xfade" 'BEGIN{printf "%.1f",3*x}')s)" >&2
    return 1
  fi

  # xfade offset: the transition begins at D - 2*XFADE
  local xfade_offset
  xfade_offset="$(awk -v d="$dur" -v x="$xfade" 'BEGIN { printf "%.6f", d - 2*x }')"

  # Output duration = D - XFADE  (the crossfaded portion reduces the unit length)
  local out_dur
  out_dur="$(awk -v d="$dur" -v x="$xfade" 'BEGIN { printf "%.6f", d - x }')"

  # The crossfade unit is built as follows:
  #
  #   Input 0: full CLIP           (provides the "body" = frames 0..D-XFADE)
  #   Input 1: CLIP trimmed to the first XFADE seconds  (the "head", re-played
  #            as the fade-in target for the closing transition)
  #
  # xfade offset = D - 2*XFADE: the transition begins here in input 0's timeline
  # and runs for XFADE seconds, ending at D - XFADE.
  #
  # We then trim the xfade output to out_dur = D - XFADE so the unit length is
  # shorter than the source.  When concat-copies follow, the head of the next
  # copy immediately continues from the very start of the clip, with no flash.
  #
  # The -t flag (not trim filter) is used to cap the output at out_dur after
  # the filtergraph completes, which is the most reliable way to truncate.

  if [[ "$has_audio" -eq 1 ]]; then
    "$FFMPEG" \
      -nostdin -loglevel error -y \
      -i "$clip" \
      -i "$clip" \
      -filter_complex "
        [1:v]trim=start=0:end=${xfade},setpts=PTS-STARTPTS[vhead];
        [0:v][vhead]xfade=transition=fade:duration=${xfade}:offset=${xfade_offset}[vxf];
        [vxf]trim=start=0:end=${out_dur},setpts=PTS-STARTPTS[vout];
        [1:a]atrim=start=0:end=${xfade},asetpts=PTS-STARTPTS[ahead];
        [0:a][ahead]acrossfade=d=${xfade}:c1=tri:c2=tri[axf];
        [axf]atrim=start=0:end=${out_dur},asetpts=PTS-STARTPTS[aout]
      " \
      -map "[vout]" \
      -map "[aout]" \
      -c:v libx264 -preset ultrafast -crf 23 \
      -c:a aac -b:a 64k \
      -pix_fmt yuv420p \
      "$out"
  else
    # Video only
    "$FFMPEG" \
      -nostdin -loglevel error -y \
      -i "$clip" \
      -i "$clip" \
      -filter_complex "
        [1:v]trim=start=0:end=${xfade},setpts=PTS-STARTPTS[vhead];
        [0:v][vhead]xfade=transition=fade:duration=${xfade}:offset=${xfade_offset}[vxf];
        [vxf]trim=start=0:end=${out_dur},setpts=PTS-STARTPTS[vout]
      " \
      -map "[vout]" \
      -an \
      -c:v libx264 -preset ultrafast -crf 23 \
      -pix_fmt yuv420p \
      "$out"
  fi
}

# ---------------------------------------------------------------------------
# _loop_native CLIP OUT
#
# Stream-copy CLIP into OUT unchanged.  The caller is responsible for
# ensuring CLIP already loops (last frame ≈ first frame).
# ---------------------------------------------------------------------------
_loop_native() {
  local clip="$1"
  local out="$2"

  "$FFMPEG" \
    -nostdin -loglevel error -y \
    -i "$clip" \
    -c copy \
    "$out"
}
