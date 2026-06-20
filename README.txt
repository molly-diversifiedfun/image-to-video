==================================================================
  make-video  —  the simple guide
  Turn a photo or a video clip into a LONG video (any length).
==================================================================

WHAT IS THIS?
-------------
A little tool that makes a long MP4 video out of:
  - a single photo,
  - a folder of photos,
  - a short video clip, or
  - a folder of short video clips.

You tell it how many HOURS you want. It makes the video. You can
add music too. Great for big screens, gallery displays, "ambient"
background videos, and YouTube uploads.

You do NOT need to know anything technical. You type one line,
drag a couple of files in, and press Enter.


==================================================================
  FIRST TIME SETUP  (you only do this once)
==================================================================

Nothing to install. Everything the tool needs is already in the
"bin" folder sitting right next to it. Just open Terminal (below)
and use it.

  - Works on Apple Silicon Macs only (M1, M2, M3, M4, M5).
    On an old Intel Mac it won't run — ask Molly for that version.

  - If the "bin" folder is ever empty, or you copied the tool to a
    brand-new Mac, run this ONE line in Terminal first:
         brew install ffmpeg
    (If "brew" isn't found, install it from https://brew.sh first —
     it's one line of copy-paste, then run the line above.)


==================================================================
  THE 3 THINGS YOU NEED TO KNOW
==================================================================

1) HOW TO OPEN TERMINAL
   Press  Command + Space , type "Terminal", press Enter.
   A window with a blinking cursor opens. That's where you type.

2) THE DRAG TRICK (so you never mistype a file path)
   Type the start of the command and a SPACE, then DRAG a file or
   folder from Finder INTO the Terminal window. Its location pastes
   in automatically. Do that everywhere you see <something> below.

3) WHAT THE NUMBER MEANS
   The number is the LENGTH IN HOURS.
        3      = 3 hours
        0.5    = 30 minutes
        0.02   = about 1 minute  (good for a quick test first!)

   TIP: Always do a quick 0.02 test before making a 3-hour file.

In the examples below, anything in <angle brackets> means "drag the
real thing in here." Keep the quotation marks.


==================================================================
  WHAT DO YOU WANT TO MAKE?   (pick one)
==================================================================

------------------------------------------------------------------
A)  ONE PHOTO  →  a long video
------------------------------------------------------------------
     bash "<make-video>" "<your photo>" 3

   Makes a 3-hour video of that photo. This is the FAST one — a
   3-hour 4K file is ready in about 90 seconds. The video appears
   right next to your photo.


------------------------------------------------------------------
B)  A FOLDER OF PHOTOS  →  each photo becomes its OWN video
------------------------------------------------------------------
     bash "<make-video>" "<folder of photos>" 3

   Every photo in the folder turns into its own 3-hour video. Good
   for batch-making a bunch at once.


------------------------------------------------------------------
C)  A FOLDER OF PHOTOS  →  ONE slideshow (photos fade into each other)
------------------------------------------------------------------
     bash "<make-video>" "<folder of photos>" --slideshow --each 1 --out "<slideshow.mp4>"

   Makes ONE long video where each photo holds, then gently fades
   into the next. "--each 1" means hold each photo for 1 hour, so
   10 photos = about a 10-hour video.

   You MUST give it "--out" and a name for the finished file.
   Extras you can add:
        --shuffle           random photo order
        --xfade 3           make the fade 3 seconds long (default 2.5)
        --fill              crop photos to fill the screen instead of
                            adding black bars around odd shapes


------------------------------------------------------------------
D)  A SHORT VIDEO CLIP  →  stretched to hours (seamless loop)
------------------------------------------------------------------
   Takes a short clip (rain, waves, clouds, a drone shot...) and loops
   it into a long video — 8 hours, 10 hours, whatever — so it can play
   in the background. The trick is hiding the "loop point" where the
   end meets the beginning.

   ┌──────────────────────────────────────────────────────────────┐
   │  JUST WANT IT PERFECT?  COPY THIS, CHANGE 3 THINGS:           │
   │                                                              │
   │    bash "<make-video>" "<your clip>" 8 --smooth \            │
   │         --fade 3 --height 1080 --out "<my-8h-video.mp4>"     │
   │                                                              │
   │  Change:  <your clip>  → drag your video file in             │
   │           8             → how many hours you want            │
   │           my-8h-video   → what to name the finished file     │
   │                                                              │
   │  That's it. --smooth makes the loop seamless (picture AND    │
   │  sound). Let it run — for 8 hours it can take a while.       │
   └──────────────────────────────────────────────────────────────┘

   WHAT --smooth DOES (in plain words)
   -----------------------------------
   Without it, the tool stitches copies of your clip together really
   fast — but that leaves a tiny blink and a faint blip every time it
   loops. --smooth re-draws the whole video in one smooth pass so the
   loop point disappears completely, in picture AND sound. It's the
   same thing a video editor does in Premiere.

   The catch: --smooth has to process the whole length, so it's SLOW
   (an 8-hour video can take a few hours — leave it running). Without
   --smooth it's fast but has that tiny blink. For a video you'll
   actually watch, use --smooth.

   IT TUNES THE SOUND FOR YOU
   --------------------------
   --smooth also LISTENS to your clip and picks how long the sound
   should blend at the loop, automatically — a few seconds for steady
   rain, longer if the sound changes a lot from start to end. You
   don't set anything. (Curious what it picked for a clip? Run:
        bash "<make-video>" "<your clip>" --detect-xfade   )

   THE OTHER KNOBS (all optional)
   ------------------------------
        --fade 3       ease in from black at the start and out to
                       black at the end — picture AND sound. Nice for
                       sleep/rain videos so it doesn't start abruptly.
        --height 1080  shrink the picture so the file isn't huge.
                       Strongly recommended for 8-hour videos.
        --xfade 6      how long the picture dissolve is, in seconds
                       (default 1). Longer = softer. --smooth will
                       never make it shorter than the sound needs.
        --out NAME.mp4 save it with the exact name you want.

   ONE STYLE CHOICE: which kind of loop?
   -------------------------------------
        --loop crossfade  (default) the end DISSOLVES into the start.
                          Use for RAIN, snow, traffic, a drone flying
                          forward — anything that can't be reversed.
        --loop pingpong   plays forward then BACKWARD. The join is
                          flawless, but everything reverses — so
                          DON'T use it for rain (the rain falls UP).
                          Great for water, clouds, fog, fire.

   Before the full render it shows a quick PREVIEW of the loop point.
   Add --yes to skip the preview and just go.


------------------------------------------------------------------
E)  A FOLDER OF VIDEO CLIPS  →  ONE long mixed video
------------------------------------------------------------------
     bash "<make-video>" "<folder of clips>" --mix 4 --out "<mixed.mp4>"

   Drop in 20-50 short clips and it builds ONE long video (here, 4
   hours) by shuffling them together with smooth crossfades between
   each clip. It never plays the same clip twice in a row, and it
   reshuffles as it goes so it doesn't feel repetitive.

   You MUST give it a number of hours AND "--out" with a file name.

   Extras you can add:
        --order name        keep the clips in filename order instead
                            of shuffling (1, 2, 3, ...)
        --seed 7            a "repeatable shuffle" — same number =
                            same order every time
        --xfade 2           make each crossfade 2 seconds (default 1.5)
        --clip-secs 30      use only the first 30 seconds of each clip
        --hardcut           snap between clips with NO crossfade
                            (much faster — good for a rough preview)

   *** IMPORTANT: this one is SLOW on purpose. ***
   Unlike the others, mixing has to fully re-process the video, so a
   multi-hour file can take a while. Before the big render it will:
        1. print a rough size + time estimate,
        2. make a SHORT preview of the first few transitions, and
        3. ask "Proceed with the full render? [Y/n]".
   Type Y and press Enter to go, or N to stop. (Add --yes to skip
   the question — handy for leaving it running overnight.)


==================================================================
  ADD MUSIC OR SOUND   (works on ALL of the above)
==================================================================

Just add "--audio" and drag in a song OR a folder of songs:

     --audio "<one song>"
            loops that one song smoothly for the whole length.

     --audio "<folder of songs>"
            plays the songs one after another (a seamless playlist),
            matches their volumes, and loops to fill the whole length.

     --keep-native
            ONLY for a video clip: play the music ON TOP of the
            clip's own sound instead of replacing it (e.g. keep the
            drone's wind AND add music). Without this, music replaces
            the clip's original sound.

Examples:
   A photo for 2 hours, with a song:
     bash "<make-video>" "<a photo>" 2 --audio "<a song>"

   A drone clip stretched to 2h, music layered over the wind:
     bash "<make-video>" "<a clip>" 2 --audio "<a song>" --keep-native

   A folder of clips mixed to 4h with a playlist of songs:
     bash "<make-video>" "<folder of clips>" --mix 4 --audio "<folder of songs>" --out "<mixed.mp4>"


==================================================================
  ALL THE OPTIONS  (cheat sheet)
==================================================================

  --slideshow         folder of PHOTOS -> one fading slideshow
  --each 1            slideshow: hold each photo this many hours
  --mix 4             folder of CLIPS  -> one shuffled mix, this many hours
  --audio "<path>"    add music: a file (loops) or a folder (playlist)
  --keep-native       layer music OVER a clip's own sound (clips only)
  --smooth            BEST for loops you'll watch: makes the loop point
                      perfectly seamless in picture AND sound, and auto-
                      tunes the sound blend for the clip. Slower (re-draws
                      the whole video), but worth it.
  --detect-xfade      just TELL me the sound-blend length it would pick
                      for a clip (doesn't make a video)
  --loop pingpong     clip loop style: invisible (forward+backward)
  --loop crossfade    clip loop style: soft blend / dissolve (default)
  --order name        mix: keep filename order (default is shuffle)
  --seed 7            slideshow/mix: repeatable random order
  --xfade 2           length of the picture dissolve, in seconds
  --fade 3            fade in from black at the start AND out to black at
                      the end (picture and sound). Great for sleep/rain
                      videos so they don't start or stop abruptly.
  --height 1080       shrink the picture to this many pixels tall. The
                      easiest way to make a long file much smaller
                      (1080 = "1080p"; a 4K clip becomes ~4x smaller).
  --crf 23            quality dial, 0-51. Lower = better but bigger.
  --gpu               mix only: use the Mac's video chip to render much
                      faster (great on an M-series Mac).
  --clip-secs 30      mix: use only the first N seconds of each clip
  --fill              crop odd-shaped inputs to fill (no black bars)
  --hardcut           mix: no crossfades (faster rough version)
  --zoom 4            photo: slow gentle zoom (SLOW — re-processes)
  --out "<path>"      where to save it: a folder, OR an exact file name
                      like  rain-8h.mp4  (works for every mode now)
  --jobs 4            how many to make at once (leave it off — it's automatic)
  --yes               skip the preview/"are you sure" question
  --help              show the built-in help

  See the full built-in help any time:
     bash "<make-video>" --help


==================================================================
  IF SOMETHING GOES WRONG
==================================================================

"command not found: bash"
   You probably didn't type "bash" and a space before dragging the
   tool in. The line is:  bash <space> "<make-video>" <space> ...

"No such file or directory"
   A path is wrong. Don't type paths by hand — use the DRAG TRICK.
   Make sure each dragged item still has its quotation marks.

"ffmpeg / ffprobe not found"
   The "bin" folder is missing or empty. Run once:
        brew install ffmpeg

"--slideshow requires a directory" / "--mix requires a directory of clips"
   You pointed slideshow or mix at a single file. They need a FOLDER.

"--mix requires --out FILE" / "--slideshow requires --out"
   You forgot to add  --out "<a name for the file>".

"shortest clip too short for the crossfade"
   In mix mode, one of your clips is shorter than the crossfade. Use
   a smaller fade, e.g.  --xfade 0.5 , or remove the tiny clip.

It looks frozen / nothing is happening
   Big videos take time, especially --mix and --zoom. Mixing shows
   progress and asks before the long part. Let it run.

The order keeps changing every time
   That's the shuffle. For the SAME order every time, add a seed,
   e.g.  --seed 7  (or use  --order name  to go in filename order).


==================================================================
  GOOD TO KNOW
==================================================================

- FAST:  photos (no zoom), slideshows, clip-looping, photo+music.
  SLOW:  --mix (folder of clips) and --zoom — they re-process video.
- Output is 4K, 30 fps, standard MP4 — uploads straight to YouTube.
- The video saves next to your source, unless you set --out.
- Always test with a tiny length first (e.g. 0.02 = ~1 minute).
- It quietly skips junk files and the hidden "._" files macOS leaves
  on USB drives, so a messy folder is fine.
- Fractional hours are allowed:  0.5 = 30 min,  1.5 = 90 min.

==================================================================
