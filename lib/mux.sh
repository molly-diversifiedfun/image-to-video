#!/usr/bin/env bash
#
# lib/mux.sh — mux_audio VIDEO AUDIO OUT
#
# Combine a video file with an external audio file into OUT:
#   - Video stream is COPIED (-c:v copy); no re-encode.
#   - Audio is encoded to AAC (-c:a aac) at 192k (-b:a 192k).
#   - If VIDEO already has an audio track it is DISCARDED; the supplied AUDIO
#     replaces it (map 0:v:0 + 1:a:0 → only one audio stream in OUT).
#   - OUT duration follows the VIDEO (master clock): -shortest ensures the
#     mux stops when the shorter of the two mapped streams ends.  Because AUDIO
#     is expected to be pre-fit to VIDEO length, duration ≈ VIDEO duration.
#   - -movflags +faststart for web-friendly atoms.
#   - Quiet: -nostdin -loglevel error -y.
#
# CALLER CONTRACT: AUDIO must be pre-fit to VIDEO duration.  If AUDIO is shorter,
# -shortest silently truncates OUT to AUDIO length (video frames after audio end
# are dropped) — no padding/looping is performed.  Pad/loop audio to length first.
#
# Dependencies: $FFMPEG must be set by the caller (fixtures.sh or make-video).
# Targets bash 3.2+.

# ---------------------------------------------------------------------------
# mux_audio VIDEO AUDIO OUT
# ---------------------------------------------------------------------------
mux_audio() {
  local video="${1:?mux_audio: VIDEO required}"
  local audio="${2:?mux_audio: AUDIO required}"
  local out="${3:?mux_audio: OUT required}"

  # Validate inputs exist; emit diagnostic to stderr and return non-zero.
  if [[ ! -f "$video" ]]; then
    echo "mux_audio: VIDEO not found: $video" >&2
    return 1
  fi
  if [[ ! -f "$audio" ]]; then
    echo "mux_audio: AUDIO not found: $audio" >&2
    return 1
  fi

  # -map 0:v:0   — take the first video stream from VIDEO
  # -map 1:a:0   — take the first audio stream from AUDIO (ignores any audio in VIDEO)
  # -c:v copy    — copy video bitstream verbatim (no re-encode)
  # -c:a aac     — encode audio to AAC
  # -b:a 192k    — explicit AAC bitrate (good for ambient music beds)
  # -shortest    — stop at the end of the shorter mapped stream
  # -movflags +faststart — write moov atom before mdat for streaming
  "$FFMPEG" \
    -nostdin -loglevel error -y \
    -i "$video" \
    -i "$audio" \
    -map 0:v:0 \
    -map 1:a:0 \
    -c:v copy \
    -c:a aac \
    -b:a 192k \
    -shortest \
    -movflags +faststart \
    "$out"
}
