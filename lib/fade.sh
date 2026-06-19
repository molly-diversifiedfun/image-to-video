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
#   the head segment [0, FADE] and the tail segment [D-FADE, D], stream-copy the
#   long middle [FADE, D-FADE] untouched, and concat-copy the three.  Render cost
#   is ~2×FADE seconds of encoding regardless of total length — the same
#   "encode only what changes, copy the rest" approach lib/mixer.sh uses.
#
#   When the file is too short to split (2×FADE >= D) we fall back to a single
#   pass over the whole (small) file.
#
# CONCAT-COMPAT
# ─────────────
#   The head/tail are re-encoded to the SAME width/height/fps/pix_fmt as the
#   source so the three pieces concat-copy cleanly (mirrors mixer's segment
#   approach).  libx264; audio re-encoded to AAC on the ends, copied in the
#   middle.  If the source has no audio stream, the output stays video-only.
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

  # ------------------------------------------------------------------
  # Short file: 2×FADE >= D → one pass over the whole (small) file.
  # ------------------------------------------------------------------
  local whole
  whole="$(awk -v d="$dur" -v f="$fade" 'BEGIN{ print (2*f >= d) ? 1 : 0 }')"
  if [[ "$whole" -eq 1 ]]; then
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
    return $?
  fi

  # ------------------------------------------------------------------
  # Split path: head (fade in) + middle (copy) + tail (fade out).
  # ------------------------------------------------------------------
  local tmp; tmp="$(mktemp -d)"
  local head="$tmp/head.mp4" mid="$tmp/mid.mp4" tail="$tmp/tail.mp4" list="$tmp/list.txt"

  # Match the source's params so the three pieces concat-copy cleanly.
  local w h pix fps
  read -r w h pix < <("$FFPROBE" -v error -select_streams v:0 \
    -show_entries stream=width,height,pix_fmt -of csv=p=0 "$in" | tr ',' ' ')
  fps="$("$FFPROBE" -v error -select_streams v:0 \
    -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 "$in")"
  pix="${pix:-yuv420p}"
  : "${w:?}" "${h:?}"

  local mid_dur
  mid_dur="$(awk -v d="$dur" -v f="$fade" 'BEGIN{ printf "%.3f", d - 2*f }')"

  local -a venc=(-c:v libx264 -preset veryfast -crf "$crf" -r "$fps" -pix_fmt "$pix")

  # HEAD — first FADE seconds, fading up from black.
  if [[ "$has_audio" -eq 1 ]]; then
    "$FFMPEG" -nostdin -loglevel error -y -i "$in" -t "$fade" \
      -vf "fade=t=in:st=0:d=${fade},format=${pix}" \
      -af "afade=t=in:st=0:d=${fade}" \
      "${venc[@]}" -c:a aac -ar 44100 -ac 2 "$head" \
      || { rm -rf "$tmp"; echo "apply_fades: head encode failed" >&2; return 1; }
  else
    "$FFMPEG" -nostdin -loglevel error -y -i "$in" -t "$fade" \
      -vf "fade=t=in:st=0:d=${fade},format=${pix}" -an \
      "${venc[@]}" "$head" \
      || { rm -rf "$tmp"; echo "apply_fades: head encode failed" >&2; return 1; }
  fi

  # MIDDLE — copy [FADE, D-FADE] untouched (the bulk; no re-encode).
  if [[ "$has_audio" -eq 1 ]]; then
    "$FFMPEG" -nostdin -loglevel error -y -ss "$fade" -i "$in" -t "$mid_dur" \
      -c copy "$mid" \
      || { rm -rf "$tmp"; echo "apply_fades: middle copy failed" >&2; return 1; }
  else
    "$FFMPEG" -nostdin -loglevel error -y -ss "$fade" -i "$in" -t "$mid_dur" \
      -c:v copy -an "$mid" \
      || { rm -rf "$tmp"; echo "apply_fades: middle copy failed" >&2; return 1; }
  fi

  # TAIL — last FADE seconds, fading down to black.
  if [[ "$has_audio" -eq 1 ]]; then
    "$FFMPEG" -nostdin -loglevel error -y -ss "$fade_out_st" -i "$in" \
      -vf "fade=t=out:st=0:d=${fade},format=${pix}" \
      -af "afade=t=out:st=0:d=${fade}" \
      "${venc[@]}" -c:a aac -ar 44100 -ac 2 "$tail" \
      || { rm -rf "$tmp"; echo "apply_fades: tail encode failed" >&2; return 1; }
  else
    "$FFMPEG" -nostdin -loglevel error -y -ss "$fade_out_st" -i "$in" \
      -vf "fade=t=out:st=0:d=${fade},format=${pix}" -an \
      "${venc[@]}" "$tail" \
      || { rm -rf "$tmp"; echo "apply_fades: tail encode failed" >&2; return 1; }
  fi

  printf "file '%s'\nfile '%s'\nfile '%s'\n" "$head" "$mid" "$tail" > "$list"
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
