# make-video PRDs

Five features, one unified tool. Read the [architecture & process design](../plans/2026-06-18-make-video-architecture.md) first — it defines the shared engines and the canonical 7-step SOP every mode follows.

| PRD | Mode | Feature | Speed |
|-----|------|---------|-------|
| [PRD-1](PRD-1-slideshow.md) | `slideshow` | N images → N hours, 1hr each, crossfaded, one file | fast |
| [PRD-2](PRD-2-seamless-loop.md) | `loop-extend` | short ambient clip → hours, invisible video+audio seam | fast |
| [PRD-3](PRD-3-clip-plus-soundtrack.md) | `loop-extend` + `--audio` | extend a clip (e.g. drone) + looped track or song playlist | fast |
| [PRD-4](PRD-4-multi-clip-mixer.md) | `mix` | folder of 20-50 clips → 2-8h shuffled w/ transitions + soundtrack | slow (re-encode) |
| [PRD-5](PRD-5-photo-plus-audio.md) | `still` + `--audio` | photo → long video with a soundtrack | fast |

Each PRD: Problem → Users → Use cases → Functional requirements → **SOP** (the ordered operational steps) → Acceptance criteria → Risks.

Status: design approved 2026-06-18, then **red-teamed** (pre-mortem) the same day. Three findings folded in:
1. "Seamless" is not free on arbitrary footage — measured a 28.6 dB crossfade-loop jump vs seamless pingpong. Now a `--loop {crossfade|pingpong|native}` choice with stated source requirements (architecture §3.2).
2. A non-technical operator can't spot a subtly-broken multi-hour output — added a `seam-check` auto-QC + a PREVIEW go/no-go gate to the SOP (architecture §4).
3. The slow/fragile mixer (PRD-4) is gated to ship last, behind the four fast modes (architecture §7).

Not yet implemented. Implementation planning is the next step.
