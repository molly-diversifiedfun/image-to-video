#!/usr/bin/env bash
#
# lib/mixer.sh — mix_clips DIR TARGET_HOURS OUT  (PRD-4 multi-clip mixer)
#
# A folder of short clips → ONE long video: clips are sequenced to fill the
# target length, every junction a crossfade (video xfade + audio acrossfade),
# no clip back-to-back with itself, reshuffled each pass.  This is the only
# mode that fully re-encodes — every unique seam is unique, so there is no
# concat-copy shortcut across the whole timeline (the bodies between seams,
# however, ARE built once and concat-copied, so render cost scales with the
# number of UNIQUE clips/seams, not with total length).
#
# Algorithm (ordered clips O_0..O_{m-1}, durations d_k, crossfade X):
#   1. Normalize each UNIQUE source clip once → project WxH / FPS / yuv420p /
#      aac (cap to MIX_CLIP_SECS if set).
#   2. sequence_clips → the ordered index list that fills the target.
#   3. For each ordered position build a "body" (the part of the clip not
#      consumed by a neighbouring dissolve) and, between neighbours, a
#      "dissolve" (X-second xfade of O_k's tail and O_{k+1}'s head).  Bodies
#      and dissolves are cached by (source,kind) / (pair) so repeats are free.
#   4. Concat-copy body_0, dissolve_0, body_1, …, body_{m-1}.
#   5. If AUDIO_PATH: build a soundtrack to the total length and mux as a
#      replacement.  Otherwise the clips' own audio is carried through.
#   6. MIX_HARDCUT=1 → skip dissolves, concat-copy whole ordered clips (fast
#      preview / fallback).
#
#   timeline(m) = Σ d_k − (m−1)·X
#
# GLOBALS (set by make-video; defaulted by callers/tests):
#   MIX_XFADE (1.5) MIX_SEED ($$) MIX_ORDER (shuffle|name) MIX_CLIP_SECS (0)
#   MIX_FILL (0) MIX_HARDCUT (0) MIX_ORDER_LOG ("") AUDIO_PATH ("")
#   FPS CRF — from make-video.
#
# DEPENDS: $FFMPEG $FFPROBE; sequence_clips (lib/sequencer.sh);
#          audio_build (lib/audio.sh); mux_audio (lib/mux.sh); awk.

# --- normalized video filter: fit (letterbox) or fill (crop) to PWxPH --------
_mix_vf() {
  local pw="$1" ph="$2" fill="${3:-0}"
  if [[ "$fill" -eq 1 ]]; then
    echo "scale=${pw}:${ph}:force_original_aspect_ratio=increase,crop=${pw}:${ph},format=yuv420p"
  else
    echo "scale=${pw}:${ph}:force_original_aspect_ratio=decrease,pad=${pw}:${ph}:(ow-iw)/2:(oh-ih)/2,format=yuv420p"
  fi
}

_mix_probe_dur() {
  "$FFPROBE" -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$1"
}

_mix_has_audio() {
  local c
  c="$("$FFPROBE" -v error -select_streams a -show_entries stream=index \
        -of csv=p=0 "$1" 2>/dev/null | grep -c .)" || c=0
  [[ "$c" -gt 0 ]]
}

# Common encode flags so every segment is concat-copy compatible.
# With MIX_GPU=1 (set by --gpu) the video is encoded on Apple Silicon's
# VideoToolbox hardware encoder instead of CPU libx264 — much faster on the
# re-encode-heavy mix mode.  VideoToolbox is rate-controlled by bitrate, not
# CRF, so quality is set via MIX_GPU_BITRATE (default 12M).  Audio params and
# resolution/fps/pix_fmt stay identical so segments remain concat-copy safe.
_mix_enc() {
  if [[ "${MIX_GPU:-0}" -eq 1 ]]; then
    printf '%s' "-c:v h264_videotoolbox -b:v ${MIX_GPU_BITRATE:-12M} -r ${FPS} \
-pix_fmt yuv420p -c:a aac -ar 44100 -ac 2"
  else
    printf '%s' "-c:v libx264 -preset veryfast -crf ${CRF} -r ${FPS} \
-pix_fmt yuv420p -c:a aac -ar 44100 -ac 2"
  fi
}

# _mix_normalize SRC OUT PW PH FILL CAP  — re-encode SRC to project params.
_mix_normalize() {
  local src="$1" out="$2" pw="$3" ph="$4" fill="$5" cap="$6"
  local vf; vf="$(_mix_vf "$pw" "$ph" "$fill")"
  local -a tflag=(); awk -v c="$cap" 'BEGIN{exit !(c>0)}' && tflag=(-t "$cap")

  # bash 3.2 + set -u: guard the possibly-empty array expansion.
  if _mix_has_audio "$src"; then
    # shellcheck disable=SC2046
    "$FFMPEG" -nostdin -loglevel error -y -i "$src" \
      -vf "$vf" $(_mix_enc) ${tflag[@]+"${tflag[@]}"} "$out"
  else
    # shellcheck disable=SC2046
    "$FFMPEG" -nostdin -loglevel error -y -i "$src" \
      -f lavfi -i "anullsrc=channel_layout=stereo:sample_rate=44100" \
      -map 0:v -map 1:a -vf "$vf" $(_mix_enc) -shortest ${tflag[@]+"${tflag[@]}"} "$out"
  fi
}

# _mix_body NORM OUT START DUR  — re-encode the [START, START+DUR] slice.
_mix_body() {
  local norm="$1" out="$2" start="$3" dur="$4"
  # shellcheck disable=SC2046
  "$FFMPEG" -nostdin -loglevel error -y -i "$norm" -ss "$start" -t "$dur" \
    $(_mix_enc) "$out"
}

# _mix_dissolve A B OUT X DA  — X-second crossfade of A's tail into B's head.
_mix_dissolve() {
  local a="$1" b="$2" out="$3" x="$4" da="$5"
  local astart; astart="$(awk -v d="$da" -v x="$x" 'BEGIN{printf "%.6f", d-x}')"
  # shellcheck disable=SC2046
  "$FFMPEG" -nostdin -loglevel error -y -i "$a" -i "$b" \
    -filter_complex \
      "[0:v]trim=start=${astart}:duration=${x},setpts=PTS-STARTPTS[av]; \
       [1:v]trim=start=0:duration=${x},setpts=PTS-STARTPTS[bv]; \
       [av][bv]xfade=transition=fade:duration=${x}:offset=0,format=yuv420p[v]; \
       [0:a]atrim=start=${astart}:duration=${x},asetpts=PTS-STARTPTS[aa]; \
       [1:a]atrim=start=0:duration=${x},asetpts=PTS-STARTPTS[ba]; \
       [aa][ba]acrossfade=d=${x}:c1=qsin:c2=qsin[a]" \
    -map "[v]" -map "[a]" $(_mix_enc) -t "$x" "$out"
}

# ---------------------------------------------------------------------------
# mix_clips DIR TARGET_HOURS OUT
# ---------------------------------------------------------------------------
mix_clips() {
  local dir="$1" target_hours="$2" out="$3"
  [[ -d "$dir" ]] || { echo "mix_clips: not a directory: $dir" >&2; return 1; }

  local xfade="${MIX_XFADE:-1.5}"
  local seed="${MIX_SEED:-$$}"
  local order="${MIX_ORDER:-shuffle}"
  local cap="${MIX_CLIP_SECS:-0}"
  local fill="${MIX_FILL:-0}"
  local hardcut="${MIX_HARDCUT:-0}"

  local target_secs
  target_secs="$(awk -v h="$target_hours" 'BEGIN{printf "%d", h*3600 + 0.5}')"
  [[ "$target_secs" -gt 0 ]] 2>/dev/null \
    || { echo "mix_clips: target must be > 0" >&2; return 1; }

  if [[ -n "${AUDIO_PATH:-}" ]]; then
    [[ -e "$AUDIO_PATH" ]] || { echo "mix_clips: --audio not found: $AUDIO_PATH" >&2; return 1; }
  fi

  # --- collect source clips (sorted, skip dotfiles/AppleDouble) ---
  local -a src=()
  while IFS= read -r -d '' f; do
    local base="${f##*/}"
    [[ "$base" == ._* || "$base" == .* ]] && continue
    [[ "$(classify_input "$f")" == "video" ]] && src+=("$f")
  done < <(find "$dir" -maxdepth 1 -mindepth 1 -type f -print0 | LC_ALL=C sort -z)

  local m_src="${#src[@]}"
  [[ "$m_src" -ge 2 ]] || { echo "mix_clips: need ≥2 clips, found $m_src" >&2; return 1; }

  local tmp_dir; tmp_dir="$(mktemp -d)"
  _mix_cleanup() { rm -rf "$tmp_dir"; }

  # --- project resolution / fps from first clip ---
  local pw ph
  read -r pw ph < <("$FFPROBE" -v error -select_streams v:0 \
    -show_entries stream=width,height -of csv=p=0 "${src[0]}" | tr ',' ' ')
  [[ -n "$pw" && -n "$ph" ]] || { echo "mix_clips: cannot read dims" >&2; _mix_cleanup; return 1; }
  if [[ "$pw" -gt 3840 ]]; then
    ph=$(( ph * 3840 / pw )); pw=3840
  fi
  pw=$(( pw - pw % 2 )); ph=$(( ph - ph % 2 ))

  # --- normalize each unique source once; record effective duration ---
  local -a norm=() dur=()
  local i
  for (( i=0; i<m_src; i++ )); do
    local nf="$tmp_dir/norm_$(printf '%03d' "$i").mp4"
    _mix_normalize "${src[$i]}" "$nf" "$pw" "$ph" "$fill" "$cap" \
      || { echo "mix_clips: normalize failed: ${src[$i]}" >&2; _mix_cleanup; return 1; }
    norm[$i]="$nf"
    dur[$i]="$(_mix_probe_dur "$nf")"
  done

  # --- validate clip length vs crossfade ---
  # interior positions trim X off BOTH ends (need dur > 2X); ends trim one (X).
  local min_dur; min_dur="$(printf '%s\n' "${dur[@]}" | sort -n | head -1)"
  if [[ "$hardcut" != "1" ]]; then
    local need; need="$(awk -v x="$xfade" 'BEGIN{printf "%.4f", 2*x + 0.05}')"
    awk -v d="$min_dur" -v n="$need" 'BEGIN{exit !(d>=n)}' || {
      printf 'mix_clips: shortest clip %.2fs too short for xfade %ss (need ≥%.2fs)\n' \
        "$min_dur" "$xfade" "$need" >&2
      _mix_cleanup; return 1; }
  fi

  # --- sequence: feed "index<TAB>dur" → ordered index list ---
  local seq_xfade="$xfade"; [[ "$hardcut" == "1" ]] && seq_xfade=0
  local order_idx
  order_idx="$(for (( i=0; i<m_src; i++ )); do printf '%d\t%s\n' "$i" "${dur[$i]}"; done \
    | sequence_clips "$target_secs" "$seq_xfade" "$seed" "$order")" \
    || { echo "mix_clips: sequencing failed" >&2; _mix_cleanup; return 1; }

  local -a ord=()
  while IFS= read -r line; do [[ -n "$line" ]] && ord+=("$line"); done <<< "$order_idx"
  local m="${#ord[@]}"

  # Bounded preview: cap the ordered list to MIX_MAX_CLIPS (used by the preview
  # gate to render just the first few junctions). 0 = no cap (full render).
  local max_clips="${MIX_MAX_CLIPS:-0}"
  if [[ "$max_clips" -gt 0 && "$max_clips" -lt "$m" ]]; then
    ord=("${ord[@]:0:$max_clips}")
    m="$max_clips"
  fi

  # --- optional order log (human-readable basenames) ---
  if [[ -n "${MIX_ORDER_LOG:-}" ]]; then
    : > "$MIX_ORDER_LOG"
    for (( i=0; i<m; i++ )); do
      printf '%s\n' "$(basename "${src[${ord[$i]}]}")" >> "$MIX_ORDER_LOG"
    done
  fi

  # Report the first junction's output-frame index (for the preview seam-check).
  if [[ -n "${MIX_FIRST_JUNCTION_OUT:-}" && "$m" -ge 2 && "$hardcut" != "1" ]]; then
    awk -v d="${dur[${ord[0]}]}" -v x="$xfade" -v fps="$FPS" \
      'BEGIN{printf "%d\n", (d - x + x/2)*fps + 0.5}' > "$MIX_FIRST_JUNCTION_OUT"
  fi

  local total_secs
  total_secs="$(_mix_sum_timeline "$xfade" "$hardcut" "${ord[@]}" -- "${dur[@]}")"

  printf '[mix] %d source clip(s) → %d in sequence, xfade %ss, target %ds, total ~%.1fs\n' \
    "$m_src" "$m" "$xfade" "$target_secs" "$total_secs"
  printf '[mix] resolution %dx%d fps %s — re-encodes (slow mode)\n' "$pw" "$ph" "$FPS"

  # --- HARDCUT: concat-copy whole ordered clips, no crossfade ---
  local list_file="$tmp_dir/concat.txt"; : > "$list_file"
  if [[ "$hardcut" == "1" ]]; then
    for (( i=0; i<m; i++ )); do printf "file '%s'\n" "${norm[${ord[$i]}]}" >> "$list_file"; done
  else
    _mix_build_segments "$tmp_dir" "$list_file" "$xfade" "$m" || { _mix_cleanup; return 1; }
  fi

  # --- assemble (concat-copy) → silent-or-native timeline ---
  local timeline="$out"
  [[ -n "${AUDIO_PATH:-}" ]] && timeline="$tmp_dir/timeline.mp4"
  "$FFMPEG" -nostdin -loglevel error -y -f concat -safe 0 -i "$list_file" \
    -c copy -movflags +faststart "$timeline" \
    || { echo "mix_clips: concat failed" >&2; _mix_cleanup; return 1; }

  # --- optional soundtrack replacement ---
  if [[ -n "${AUDIO_PATH:-}" ]]; then
    local ts; ts="$(awk -v t="$total_secs" 'BEGIN{printf "%d", t+0.5}')"
    local audio="$tmp_dir/audio.aac"
    audio_build "$AUDIO_PATH" "$ts" "$audio" || { _mix_cleanup; return 1; }
    mux_audio "$timeline" "$audio" "$out" || { _mix_cleanup; return 1; }
  fi

  printf '[mix] VERIFY: expected ~%.1fs, actual ' "$total_secs"
  # `|| true` so a flaky probe never aborts before cleanup (set -e + pipefail).
  { "$FFPROBE" -v error -show_entries format=duration \
      -of default=noprint_wrappers=1:nokey=1 "$out" | awk '{printf "%.1fs\n",$1}'; } || true
  printf '✓ mix  (%d clips, %ss xfade, ~%.1fs)  ->  %s\n' "$m" "$xfade" "$total_secs" "$out"

  _mix_cleanup
}

# _mix_sum_timeline XFADE HARDCUT ord... -- dur...
# total = Σ d(ord_k) − (m−1)·X   (X=0 when hardcut).
_mix_sum_timeline() {
  local xfade="$1" hardcut="$2"; shift 2
  local -a ord=() durs=(); local seen_sep=0 a
  for a in "$@"; do
    if [[ "$a" == "--" ]]; then seen_sep=1; continue; fi
    [[ "$seen_sep" -eq 0 ]] && ord+=("$a") || durs+=("$a")
  done
  local x="$xfade"; [[ "$hardcut" == "1" ]] && x=0
  local sum=0 k
  for k in "${ord[@]}"; do
    sum="$(awk -v s="$sum" -v d="${durs[$k]}" 'BEGIN{printf "%.6f", s+d}')"
  done
  awk -v s="$sum" -v m="${#ord[@]}" -v x="$x" 'BEGIN{printf "%.6f", s-(m-1)*x}'
}

# _mix_build_segments TMP LIST XFADE M
# Builds bodies + dissolves into LIST.  Segments are cached by filename: a clip
# reused in the same role (first/last/interior) or a repeated neighbour pair
# reuses its already-built file via the `[[ -f ]]` guard, so render cost scales
# with UNIQUE clips/pairs, not total length.
# Reads the caller's `ord`, `norm`, `dur` arrays from the enclosing scope.
_mix_build_segments() {
  local tmp="$1" list="$2" x="$3" m="$4"
  local i s
  for (( i=0; i<m; i++ )); do
    s="${ord[$i]}"
    local bf
    if [[ "$m" -eq 1 ]]; then
      bf="$tmp/body_whole_${s}.mp4"
      [[ -f "$bf" ]] || _mix_body "${norm[$s]}" "$bf" 0 "${dur[$s]}" || return 1
    elif [[ "$i" -eq 0 ]]; then
      bf="$tmp/body_first_${s}.mp4"
      local d; d="$(awk -v a="${dur[$s]}" -v x="$x" 'BEGIN{printf "%.6f", a-x}')"
      [[ -f "$bf" ]] || _mix_body "${norm[$s]}" "$bf" 0 "$d" || return 1
    elif [[ "$i" -eq $(( m - 1 )) ]]; then
      bf="$tmp/body_last_${s}.mp4"
      local d; d="$(awk -v a="${dur[$s]}" -v x="$x" 'BEGIN{printf "%.6f", a-x}')"
      [[ -f "$bf" ]] || _mix_body "${norm[$s]}" "$bf" "$x" "$d" || return 1
    else
      bf="$tmp/body_mid_${s}.mp4"
      local d; d="$(awk -v a="${dur[$s]}" -v x="$x" 'BEGIN{printf "%.6f", a-2*x}')"
      [[ -f "$bf" ]] || _mix_body "${norm[$s]}" "$bf" "$x" "$d" || return 1
    fi
    printf "file '%s'\n" "$bf" >> "$list"

    if [[ "$i" -lt $(( m - 1 )) ]]; then
      local s2="${ord[$((i+1))]}"
      local dz="$tmp/diss_${s}_${s2}.mp4"
      [[ -f "$dz" ]] || _mix_dissolve "${norm[$s]}" "${norm[$s2]}" "$dz" "$x" "${dur[$s]}" || return 1
      printf "file '%s'\n" "$dz" >> "$list"
    fi
  done
}
