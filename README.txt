================================================================
  make-video — turn a photo OR a video clip into a long video
================================================================

Makes an MP4 of any length from a photo or a short video clip.
Optionally adds music/sound. Great for screens, displays, and YouTube.

----------------------------------------------------------------
SETUP
----------------------------------------------------------------
Nothing to install. Everything this tool needs is already inside the
"bin" folder next to it. Just open Terminal and use it (below).

(If the "bin" folder is ever empty or you moved the tool somewhere new,
run  brew install ffmpeg  once and it'll keep working.)

(Apple Silicon Mac only — M1/M2/M3/M4/M5. If you ever move this to an
Intel Mac it won't run; ask Molly for the Intel version.)

----------------------------------------------------------------
HOW TO USE IT
----------------------------------------------------------------
In Terminal, type the command, then a SPACE, then DRAG the script
(make-video) and your image/clip/folder into the window so the paths fill in.
The number at the end is the length in HOURS (3 = 3 hours; 0.5 = 30 min;
0.02 ≈ 1 minute for a quick test). Output appears next to the source.

  *** PHOTO → long video ***
     bash "<make-video>" "<a photo>" 3

  *** FOLDER of photos → each becomes its own video ***
     bash "<make-video>" "<image folder>" 3

  *** VIDEO CLIP → stretched to hours, seamless loop ***
     bash "<make-video>" "<a short clip>" 8 --loop pingpong

----------------------------------------------------------------
ADD MUSIC / SOUND  (works on any of the above)
----------------------------------------------------------------
  --audio "<one song>"      loops that song smoothly for the whole length
  --audio "<a song folder>" plays the songs back-to-back (a seamless
                            playlist), volume-matched, looped to fill
  --keep-native             when the input is a VIDEO CLIP, play the music
                            ON TOP OF the clip's own sound instead of
                            replacing it (e.g. keep drone wind + add music).
                            Without this, music replaces the clip's sound.

Example — a photo for 2 hours with a song:
     bash "<make-video>" "<a photo>" 2 --audio "<a song>"

Example — a drone clip stretched to 2h, music layered over the wind:
     bash "<make-video>" "<a clip>" 2 --audio "<a song>" --keep-native

----------------------------------------------------------------
STRETCHING A VIDEO CLIP (the loop)  — important
----------------------------------------------------------------
  --loop pingpong   TRULY seamless — plays forward then backward so the
                    join is invisible. Best for water/clouds/fog/abstract.
                    (It reverses motion on the way back, so a clip that
                    moves in one direction — e.g. a drone flying forward —
                    will look like it rewinds. Use crossfade for those.)
  --loop crossfade  (default) gently blends the loop point. Hides the
                    "jump" but isn't perfectly invisible on moving footage.

Before it makes the full long file, it shows you a short PREVIEW of the
loop point and tells you how seamless it is — so you can stop and switch
to --loop pingpong if you don't like it. (Add --yes to skip the preview.)

----------------------------------------------------------------
OPTIONS
----------------------------------------------------------------
  --zoom 4     subtle slow zoom on a PHOTO (SLOW: re-encodes every frame).
  --out "<folder>"   put the .mp4s in a specific folder.
  --jobs 4     how many to render at once (auto if omitted).
  --yes        skip the loop preview and just render.

----------------------------------------------------------------
GOOD TO KNOW
----------------------------------------------------------------
- Photos with no zoom are FAST (a 3-hour 4K file in ~90 seconds).
  --zoom and video-clip looping take longer (they re-encode).
- Output is 4K, 30 fps, standard MP4 — uploads straight to YouTube.
- Skips non-media files and the hidden "._" files macOS leaves on drives.
- See every option with:   bash "<make-video>" --help
================================================================
