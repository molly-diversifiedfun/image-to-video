#!/usr/bin/env bash
#
# lib/fade.sh — apply_fades IN FADE OUT
#
# Fade the whole video UP from black (and audio up from silence) over the first
# FADE seconds, and DOWN to black (audio to silence) over the last FADE seconds.
# This is the standard top-and-tail polish for ambient/sleep loops.
#
# SPEED
# ─────
#   A multi-hour loop is a stream-copy, so re-encoding the entire file just to
#   fade a few seconds at each end would be wasteful.  Instead we re-encode ONLY
#   a head segment and a tail segment and stream-copy the long middle untouched,
#   then concat-copy the three.  Render cost is ~one GOP of encoding at each end
#   regardless of total length — the same "encode only what changes, copy the
#   rest" approach lib/mixer.sh uses.
#
# WHY KEYFRAME-ALIGNED CUTS
# ─────────────────────────
#   Stream-copy can only start a segment on a keyframe.  Cutting the middle at
#   an arbitrary time would snap back to the previous keyframe and DUPLICATE the
#   content the faded head already showed (a visible rewind right after the
#   fade-in).  So we cut the middle on real keyframe boundaries: head = [0, k1]
#   where k1 is the first keyframe at/after FADE; middle = copy [k1, k2] where
#   k2 is the last keyframe at/before D-FADE; tail = [k2, D].  The keyframe
#   probes are time-bounded (-read_intervals) so they stay fast even on an 8h
#   file.  If no usable keyframes are found (e.g. a single-GOP source) we fall
#   back to a correct whole-file re-encode.
#
#   When the file is too short to split (2×FADE >= D) we also use the whole-file
#   single pass.
#
# CONCAT-COMPAT
# ─────────────
#   The head/tail are re-encoded to the SAME width/height/fps/pix_fmt as the
#   source so the three pieces concat-copy cleanly (mirrors mixer's segments).
#   libx264; audio re-encoded to AAC on the ends, copied in the middle.  A
#   source with no audio stream yields a video-only output.
#
# DEPENDENCIES
# ────────────
#   $FFMPEG / $FFPROBE set by the caller.  Targets bash 3.2+.  awk for floats.

_fade_dur() {
  "$FFPROBE" -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$1"
}

_fade_has_audio() {
  local c
  c="$("$FFPROBE" -v error -select_streams a -show_entries stream=index \
        -of csv=p=0 "$1" 2>/dev/null | grep -c .)" || c=0
  [[ "${c:-0}" -ge 1 ]]
}

# First keyframe presentation time at/after T (scanning only [T, T+90] so this
# is fast on long files).  Reads packet flags — no decoding.  Empty if none.
_fade_kf_after() {
  local file="$1" t="$2"
  "$FFPROBE" -v error -select_streams v:0 -read_intervals "${t}%+90" \
    -show_entries packet=pts_time,flags -of csv=p=0 "$file" 2>/dev/null \
    | awk -F, -v t="$t" '$2 ~ /K/ && $1+0 >= t-0.0005 { printf "%.3f", $1+0; exit }'
}

# Last keyframe presentation time at/before T (scanning only [T-90, T]).
_fade_kf_before() {
  local file="$1" t="$2" start
  start="$(awk -v t="$t" 'BEGIN{ x=t-90; if (x<0) x=0; printf "%.3f", x }')"
  "$FFPROBE" -v error -select_streams v:0 -read_intervals "${start}%${t}" \
    -show_entries packet=pts_time,flags -of csv=p=0 "$file" 2>/dev/null \
    | awk -F, -v t="$t" '$2 ~ /K/ && $1+0 <= t+0.0005 { k=$1+0 } END{ if (k != "") printf "%.3f", k }'
}

# Single-pass fade over the WHOLE file.  Used for short files and as the
# fallback when keyframe-aligned splitting isn't possible.
_fade_whole_file() {
  local in="$1" fade="$2" out="$3" fade_out_st="$4" has_audio="$5" crf="$6"
  local vf="fade=t=in:st=0:d=${fade},fade=t=out:st=${fade_out_st}:d=${fade}"
  if [[ "$has_audio" -eq 1 ]]; then
    "$FFMPEG" -nostdin -loglevel error -y -i "$in" \
      -vf "$vf" \
      -af "afade=t=in:st=0:d=${fade},afade=t=out:st=${fade_out_st}:d=${fade}" \
      -c:v libx264 -preset veryfast -crf "$crf" -pix_fmt yuv420p \
      -c:a aac -b:a 192k -movflags +faststart "$out"
  else
    "$FFMPEG" -nostdin -loglevel error -y -i "$in" \
      -vf "$vf" -an \
      -c:v libx264 -preset veryfast -crf "$crf" -pix_fmt yuv420p \
      -movflags +faststart "$out"
  fi
}

# ---------------------------------------------------------------------------
# apply_fades IN FADE OUT
# ---------------------------------------------------------------------------
apply_fades() {
  local in="${1:?apply_fades: IN required}"
  local fade="${2:?apply_fades: FADE required}"
  local out="${3:?apply_fades: OUT required}"

  [[ -f "$in" ]] || { echo "apply_fades: IN not found: $in" >&2; return 1; }

  local dur
  dur="$(_fade_dur "$in")" || { echo "apply_fades: cannot read duration: $in" >&2; return 1; }
  [[ "$dur" =~ ^[0-9] ]] || { echo "apply_fades: bad duration for $in" >&2; return 1; }

  local has_audio=0
  _fade_has_audio "$in" && has_audio=1
  local crf="${CRF:-20}"

  # fade-out starts FADE seconds before the end.
  local fade_out_st
  fade_out_st="$(awk -v d="$dur" -v f="$fade" 'BEGIN{ printf "%.3f", d - f }')"

  # Short file: 2×FADE >= D → one pass over the whole (small) file.
  if awk -v d="$dur" -v f="$fade" 'BEGIN{ exit !(2*f >= d) }'; then
    _fade_whole_file "$in" "$fade" "$out" "$fade_out_st" "$has_audio" "$crf"
    return $?
  fi

  # ------------------------------------------------------------------
  # Split path: head (fade in) [+ copied middle +] tail (fade out),
  # cut on real keyframe boundaries so the copied middle never rewinds.
  # ------------------------------------------------------------------
  local k1 k2
  k1="$(_fade_kf_after "$in" "$fade")"
  k2="$(_fade_kf_before "$in" "$fade_out_st")"

  # Need both keyframes, with fade <= k1 <= k2 <= fade_out_st.  Otherwise the
  # source's keyframes are too sparse to split cleanly — re-encode whole file.
  if [[ -z "$k1" || -z "$k2" ]] \
     || awk -v a="$k1" -v b="$k2" 'BEGIN{ exit !(a > b + 0.0005) }'; then
    _fade_whole_file "$in" "$fade" "$out" "$fade_out_st" "$has_audio" "$crf"
    return $?
  fi

  local tmp; tmp="$(mktemp -d)"
  local head="$tmp/head.mp4" mid="$tmp/mid.mp4" tail="$tmp/tail.mp4" list="$tmp/list.txt"

  # Match the source's params so the pieces concat-copy cleanly.
  local w h pix fps
  read -r w h pix < <("$FFPROBE" -v error -select_streams v:0 \
    -show_entries stream=width,height,pix_fmt -of csv=p=0 "$in" | tr ',' ' ')
  fps="$("$FFPROBE" -v error -select_streams v:0 \
    -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 "$in")"
  pix="${pix:-yuv420p}"
  : "${w:?}" "${h:?}"

  local -a venc=(-c:v libx264 -preset veryfast -crf "$crf" -r "$fps" -pix_fmt "$pix")

  # HEAD — [0, k1], fading up from black over the first FADE seconds.
  if [[ "$has_audio" -eq 1 ]]; then
    "$FFMPEG" -nostdin -loglevel error -y -i "$in" -t "$k1" \
      -vf "fade=t=in:st=0:d=${fade},format=${pix}" \
      -af "afade=t=in:st=0:d=${fade}" \
      "${venc[@]}" -c:a aac -ar 44100 -ac 2 "$head" \
      || { rm -rf "$tmp"; echo "apply_fades: head encode failed" >&2; return 1; }
  else
    "$FFMPEG" -nostdin -loglevel error -y -i "$in" -t "$k1" \
      -vf "fade=t=in:st=0:d=${fade},format=${pix}" -an \
      "${venc[@]}" "$head" \
      || { rm -rf "$tmp"; echo "apply_fades: head encode failed" >&2; return 1; }
  fi

  # MIDDLE — copy [k1, k2] untouched (the bulk; no re-encode).  k1 is a real
  # keyframe so the input-seek lands exactly there with no duplication.  Skipped
  # when k1 == k2 (head meets tail directly).
  local have_mid=0
  if awk -v a="$k1" -v b="$k2" 'BEGIN{ exit !(b > a + 0.0005) }'; then
    have_mid=1
    local mid_dur; mid_dur="$(awk -v a="$k1" -v b="$k2" 'BEGIN{ printf "%.3f", b - a }')"
    if [[ "$has_audio" -eq 1 ]]; then
      "$FFMPEG" -nostdin -loglevel error -y -ss "$k1" -i "$in" -t "$mid_dur" \
        -c copy "$mid" \
        || { rm -rf "$tmp"; echo "apply_fades: middle copy failed" >&2; return 1; }
    else
      "$FFMPEG" -nostdin -loglevel error -y -ss "$k1" -i "$in" -t "$mid_dur" \
        -c:v copy -an "$mid" \
        || { rm -rf "$tmp"; echo "apply_fades: middle copy failed" >&2; return 1; }
    fi
  fi

  # TAIL — [k2, D], fading down to black over the last FADE seconds.  The
  # fade-out begins at (fade_out_st - k2) in the tail's local timeline.
  local tail_fade_st
  tail_fade_st="$(awk -v fo="$fade_out_st" -v k="$k2" 'BEGIN{ v=fo-k; if (v<0) v=0; printf "%.3f", v }')"
  if [[ "$has_audio" -eq 1 ]]; then
    "$FFMPEG" -nostdin -loglevel error -y -ss "$k2" -i "$in" \
      -vf "fade=t=out:st=${tail_fade_st}:d=${fade},format=${pix}" \
      -af "afade=t=out:st=${tail_fade_st}:d=${fade}" \
      "${venc[@]}" -c:a aac -ar 44100 -ac 2 "$tail" \
      || { rm -rf "$tmp"; echo "apply_fades: tail encode failed" >&2; return 1; }
  else
    "$FFMPEG" -nostdin -loglevel error -y -ss "$k2" -i "$in" \
      -vf "fade=t=out:st=${tail_fade_st}:d=${fade},format=${pix}" -an \
      "${venc[@]}" "$tail" \
      || { rm -rf "$tmp"; echo "apply_fades: tail encode failed" >&2; return 1; }
  fi

  : > "$list"
  printf "file '%s'\n" "$head" >> "$list"
  [[ "$have_mid" -eq 1 ]] && printf "file '%s'\n" "$mid" >> "$list"
  printf "file '%s'\n" "$tail" >> "$list"

  if [[ "$has_audio" -eq 1 ]]; then
    "$FFMPEG" -nostdin -loglevel error -y -f concat -safe 0 -i "$list" \
      -c copy -movflags +faststart "$out"
  else
    "$FFMPEG" -nostdin -loglevel error -y -f concat -safe 0 -i "$list" \
      -c:v copy -an -movflags +faststart "$out"
  fi
  local st=$?
  rm -rf "$tmp"
  return $st
}
