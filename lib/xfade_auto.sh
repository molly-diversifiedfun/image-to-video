#!/usr/bin/env bash
#
# lib/xfade_auto.sh — detect_audio_xfade CLIP [MIN] [MAXFRAC]
#
# Auto-pick an AUDIO crossfade length for a seamless loop of CLIP, by measuring
# how different the clip's start and end ambience are RELATIVE to how fast the
# clip's ambience naturally drifts.
#
# THE IDEA (self-calibrating — no magic threshold)
# ────────────────────────────────────────────────
#   A loop's audio seam is audible when the crossfade morphs the soundscape
#   FASTER than the soundscape naturally changes inside the clip.  So:
#     endpoint_gap  = how different the head and tail ambience are
#     drift_rate    = how much the ambience naturally changes per window
#     xfade ≈ (endpoint_gap / drift_rate) windows  — i.e. stretch the crossfade
#             until the endpoint gap is bridged at the clip's OWN natural rate.
#   Stationary ambience (steady rain) → small gap, short xfade.  Drifting
#   ambience (wind builds, a bird only at the end) → large gap, long xfade.
#
# FINGERPRINT
#   3 frequency bands (low <300Hz, mid 300–3k, high >3k), per-window RMS in dB.
#   The per-window distance is the Euclidean distance over those 3 bands.
#
# OUTPUT
#   Prints the recommended audio-crossfade SECONDS (clamped to [MIN, D×MAXFRAC]).
#   With XFADE_AUTO_VERBOSE=1, also prints the gap / drift / reasoning to stderr.
#
# DEPENDENCIES
#   $FFMPEG / $FFPROBE set by the caller; python3 for the arithmetic.  bash 3.2+.

_xa_band_series() {  # CLIP FILTER OUTFILE — per-window RMS (dB) for one band
  "$FFMPEG" -nostdin -loglevel error -y -i "$1" -ac 1 -ar 16000 \
    -af "${2},asetnsamples=n=16000:p=0,astats=metadata=1:reset=1,ametadata=mode=print:key=lavfi.astats.Overall.RMS_level:file=${3}" \
    -f null - 2>/dev/null
}

# detect_audio_xfade CLIP [MIN_SECS] [MAX_FRACTION_OF_DURATION]
detect_audio_xfade() {
  local clip="${1:?detect_audio_xfade: CLIP required}"
  local min_secs="${2:-3}"
  local max_frac="${3:-0.3333}"

  local dur
  dur="$("$FFPROBE" -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$clip")" || return 1

  # No audio stream → nothing to crossfade; fall back to the min.
  local has_a
  has_a="$("$FFPROBE" -v error -select_streams a -show_entries stream=index \
    -of csv=p=0 "$clip" 2>/dev/null | grep -c .)" || has_a=0
  if [[ "${has_a:-0}" -lt 1 ]]; then printf '%s' "$min_secs"; return 0; fi

  local tmp; tmp="$(mktemp -d)"
  _xa_band_series "$clip" "lowpass=f=300"               "$tmp/low.txt"
  _xa_band_series "$clip" "highpass=f=300,lowpass=f=3000" "$tmp/mid.txt"
  _xa_band_series "$clip" "highpass=f=3000"             "$tmp/high.txt"

  local result
  result="$(python3 - "$tmp/low.txt" "$tmp/mid.txt" "$tmp/high.txt" "$dur" "$min_secs" "$max_frac" <<'PY'
import sys
def series(p):
    out=[]
    for ln in open(p):
        if "RMS_level=" in ln:
            v=ln.split("RMS_level=")[1].strip()
            try:
                f=float(v)
                # silence shows as -inf / very low; clamp so distances stay finite
                if f < -120: f=-120.0
                out.append(f)
            except ValueError:
                pass
    return out
lo,mi,hi=series(sys.argv[1]),series(sys.argv[2]),series(sys.argv[3])
D=float(sys.argv[4]); MIN=float(sys.argv[5]); MAXF=float(sys.argv[6])
n=min(len(lo),len(mi),len(hi))
if n < 8:
    print(f"{MIN:.1f}"); sys.exit(0)
fp=[(lo[i],mi[i],hi[i]) for i in range(n)]
def dist(a,b): return ((a[0]-b[0])**2+(a[1]-b[1])**2+(a[2]-b[2])**2)**0.5
# natural per-window drift = median frame-to-frame fingerprint change
steps=sorted(dist(fp[i],fp[i+1]) for i in range(n-1))
drift=steps[len(steps)//2]
# endpoint gap = head (first K windows averaged) vs tail (last K windows)
K=max(1,n//12)
def avg(seg):
    m=len(seg); return tuple(sum(s[j] for s in seg)/m for j in range(3))
gap=dist(avg(fp[:K]), avg(fp[-K:]))
win_s=D/n  # seconds per window
SAFETY=1.5
if drift < 1e-6: drift=1e-6
xfade = (gap/drift)*win_s*SAFETY
lo_c, hi_c = MIN, D*MAXF
xc=max(lo_c,min(hi_c,xfade))
if "VERBOSE" in __import__("os").environ.get("XFADE_AUTO_VERBOSE_FLAG",""):
    pass
import os
if os.environ.get("XFADE_AUTO_VERBOSE")=="1":
    sys.stderr.write(f"  gap={gap:.2f}dB  drift={drift:.2f}dB/win  win={win_s:.2f}s  raw={xfade:.1f}s  → {xc:.1f}s (clamped [{lo_c:.0f},{hi_c:.1f}])\n")
print(f"{xc:.1f}")
PY
)"
  rm -rf "$tmp"
  printf '%s' "$result"
}
