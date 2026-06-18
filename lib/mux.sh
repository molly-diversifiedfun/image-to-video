#!/usr/bin/env bash
#
# lib/mux.sh — mux_audio VIDEO AUDIO OUT
#              mux_audio_layer VIDEO MUSIC OUT
#
# mux_audio  — REPLACE: combines VIDEO + external AUDIO into OUT, discarding
#              any native audio track from VIDEO.
# mux_audio_layer — LAYER: mixes VIDEO's native audio (0:a:0) with MUSIC (1:a:0)
#              via amix, then encodes the mix as AAC into OUT.
#
# Both functions:
#   - Video stream COPIED (-c:v copy); no re-encode.
#   - Audio encoded to AAC (-c:a aac) at 192k (-b:a 192k).
#   - -movflags +faststart for web-friendly atoms.
#   - Quiet: -nostdin -loglevel error -y.
#
# mux_audio CALLER CONTRACT: AUDIO must be pre-fit to VIDEO duration.  If AUDIO
# is shorter, -shortest silently truncates OUT to AUDIO length (video frames after
# audio end are dropped) — no padding/looping is performed.
#
# mux_audio_layer CALLER CONTRACT: VIDEO must have a native audio track (stream
# 0:a:0); MUSIC must be pre-fit to VIDEO duration; caller guarantees both.
# If VIDEO has no native audio track, the function returns 1 with a clear message.
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

# ---------------------------------------------------------------------------
# mux_audio_layer VIDEO MUSIC OUT
#
# Layer (mix) VIDEO's native audio with MUSIC into OUT:
#   - Both audio streams (VIDEO 0:a:0 + MUSIC 1:a:0) are mixed via amix.
#   - amix duration=first → mix follows VIDEO's audio length (master clock).
#   - dropout_transition=0 → no fade when one input ends.
#   - Video stream is COPIED (-c:v copy); no re-encode.
#   - Mixed audio encoded to AAC (-c:a aac) at 192k (-b:a 192k).
#   - -movflags +faststart for web-friendly atoms.
#   - Quiet: -nostdin -loglevel error -y.
#
# Fails with a clear stderr message + return 1 if VIDEO or MUSIC is missing,
# or if VIDEO has no audio track.
# ---------------------------------------------------------------------------
mux_audio_layer() {
  local video="${1:?mux_audio_layer: VIDEO required}"
  local music="${2:?mux_audio_layer: MUSIC required}"
  local out="${3:?mux_audio_layer: OUT required}"

  # Validate inputs exist; emit diagnostic to stderr and return non-zero.
  if [[ ! -f "$video" ]]; then
    echo "mux_audio_layer: VIDEO not found: $video" >&2
    return 1
  fi
  if [[ ! -f "$music" ]]; then
    echo "mux_audio_layer: MUSIC not found: $music" >&2
    return 1
  fi

  # Guard: VIDEO must have a native audio track to layer over.
  local native_count
  native_count="$("$FFPROBE" -v error \
    -select_streams a \
    -show_entries stream=index \
    -of csv=p=0 \
    "$video" | grep -c .)" || true
  native_count="${native_count:-0}"
  if [[ "$native_count" -lt 1 ]]; then
    echo "mux_audio_layer: VIDEO has no audio track to layer over: $video" >&2
    return 1
  fi

  # [0:a] = VIDEO native audio (stream 0:a:0)
  # [1:a] = MUSIC bed (stream 1:a:0)
  # amix=inputs=2:duration=first — mix both; output length = VIDEO audio length
  # dropout_transition=0 — no fade on stream end
  "$FFMPEG" \
    -nostdin -loglevel error -y \
    -i "$video" \
    -i "$music" \
    -filter_complex "[0:a][1:a]amix=inputs=2:duration=first:dropout_transition=0[aout]" \
    -map 0:v:0 \
    -map "[aout]" \
    -c:v copy \
    -c:a aac \
    -b:a 192k \
    -movflags +faststart \
    "$out"
}
