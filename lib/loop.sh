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
#     crossfade  (default)
#     OUT = a loop unit whose REAL tail dissolves into its REAL head over the
#     xfade window, with the dissolve landing on the loop seam.  Built so the
#     unit's first and last frames are the SAME source frame (CLIP@xfade):
#     concat-copies then join seam-to-seam with NO hard-cut flash and NO
#     backward content jump, and the dissolve straddles the boundary.
#
#     This is the strategy to use when the source CANNOT be reversed (rain,
#     falling/directional motion) so pingpong is unusable.  The seam is a
#     blend, not a pixel-identical match, so on sharp high-motion content a
#     faint dissolve may still be perceptible — widen the window (e.g.
#     --xfade 5) to make it imperceptible.
#
#     CLIP must be at least 3× xfade duration (a 5 s dissolve needs a ≥15 s
#     clip).  Shorter clips are rejected with a non-zero exit + stderr.
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
      -c:v libx264 -preset ultrafast -crf ${LOOP_CRF:-23} \
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
      -c:v libx264 -preset ultrafast -crf ${LOOP_CRF:-23} \
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

# NOTE on memory usage: the `reverse` and `areverse` filters used above buffer
# the ENTIRE clip in RAM before emitting any output.  This is acceptable for
# short clips but becomes prohibitive for long ones.  Rough ceiling: avoid
# pingpong on clips longer than ~10 minutes (a 1080p/30fps clip at that length
# can require several GB of RAM).  For longer sources, consider splitting into
# a shorter representative segment before passing to loop_unit.

# ---------------------------------------------------------------------------
# _loop_crossfade CLIP OUT HAS_AUDIO XFADE
#
# Build OUT = a loop unit whose REAL tail dissolves into its REAL head, with
# the dissolve landing exactly on the loop seam — so concat-copies flow
# continuously with NO hard-cut flash AND NO backward content jump.
#
# Technique (standard seamless-crossfade-loop construction):
#   Let D = CLIP duration, X = XFADE window.  The unit is built from:
#     - body : CLIP[X .. D]          (content X..D, length D - X)
#     - head : CLIP[0 .. X]          (content 0..X, the fade-in target)
#   xfade(body, head) with offset = D - 2*X dissolves the body's last X
#   seconds (= CLIP's real tail, content D-X..D) into the head (content 0..X)
#   over X seconds, finishing exactly at the unit's end (D - X).
#
#   Crucially the body STARTS at content X and the dissolve ENDS at content X,
#   so the unit's first and last frames are the SAME source frame (CLIP@X).
#   When copies are concat-copied the seam joins content-X to content-X: the
#   playhead never jumps backward, and the X-second dissolve straddles the
#   boundary (tail-of-pass-N dissolving into head-of-pass-N+1).
#
#   This is the right tool when the source CANNOT be reversed (e.g. rain,
#   falling motion) so pingpong is unusable.  Unlike pingpong the seam is a
#   blend, not a pixel-identical match, so on sharp high-motion content a
#   faint dissolve is still perceptible — widen XFADE (e.g. --xfade 5) to make
#   it imperceptible.  The previous build dissolved into the head but then
#   restarted the unit at content 0, leaving an X-second backward JUMP at the
#   seam (the "abrupt cut"); starting the body at content X removes it.
#
# Requirement: D >= 3 * XFADE (offset stays positive and at least X seconds of
# clean body remains between the seam and the dissolve).  So a 5 s dissolve
# needs a source clip of at least 15 s.
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
  #   body : [0:v]/[0:a] trimmed to start=XFADE  → CLIP[X..D] (content X..D)
  #   head : [1:v]/[1:a] trimmed to 0..XFADE     → CLIP[0..X] (content 0..X)
  #
  # xfade/acrossfade(body, head) with offset = D - 2*XFADE (body-local time):
  # the body plays clean for D - 2*XFADE seconds (content X..D-X), then its
  # last XFADE seconds (content D-X..D, the real tail) dissolve into the head
  # (content 0..X) over XFADE seconds, finishing at body-local D - XFADE.
  #
  # xfade output length = body_len + head_len - XFADE = (D-X) + X - X = D - X,
  # which equals out_dur; the trailing trim only guards fps rounding.  Because
  # the unit begins at content X and ends at content X, concat-copies join
  # seam-to-seam with no backward jump and the dissolve straddles the boundary.

  if [[ "$has_audio" -eq 1 ]]; then
    "$FFMPEG" \
      -nostdin -loglevel error -y \
      -i "$clip" \
      -i "$clip" \
      -filter_complex "
        [0:v]trim=start=${xfade},setpts=PTS-STARTPTS[vbody];
        [1:v]trim=start=0:end=${xfade},setpts=PTS-STARTPTS[vhead];
        [vbody][vhead]xfade=transition=fade:duration=${xfade}:offset=${xfade_offset}[vxf];
        [vxf]trim=start=0:end=${out_dur},setpts=PTS-STARTPTS[vout];
        [0:a]atrim=start=${xfade},asetpts=PTS-STARTPTS[abody];
        [1:a]atrim=start=0:end=${xfade},asetpts=PTS-STARTPTS[ahead];
        [abody][ahead]acrossfade=d=${xfade}:c1=qsin:c2=qsin[axf];
        [axf]atrim=start=0:end=${out_dur},asetpts=PTS-STARTPTS[aout]
      " \
      -map "[vout]" \
      -map "[aout]" \
      -c:v libx264 -preset ultrafast -crf ${LOOP_CRF:-23} \
      -c:a aac -b:a 64k \
      -pix_fmt yuv420p \
      "$out" || { echo "loop_unit: crossfade encode failed" >&2; return 1; }
  else
    # Video only
    "$FFMPEG" \
      -nostdin -loglevel error -y \
      -i "$clip" \
      -i "$clip" \
      -filter_complex "
        [0:v]trim=start=${xfade},setpts=PTS-STARTPTS[vbody];
        [1:v]trim=start=0:end=${xfade},setpts=PTS-STARTPTS[vhead];
        [vbody][vhead]xfade=transition=fade:duration=${xfade}:offset=${xfade_offset}[vxf];
        [vxf]trim=start=0:end=${out_dur},setpts=PTS-STARTPTS[vout]
      " \
      -map "[vout]" \
      -an \
      -c:v libx264 -preset ultrafast -crf ${LOOP_CRF:-23} \
      -pix_fmt yuv420p \
      "$out" || { echo "loop_unit: crossfade encode failed" >&2; return 1; }
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
