================================================================
  ImageToVideo — turn a still image into a long silent video
================================================================

Makes an MP4 of any length from a photo. No sound. Great for screens,
displays, and YouTube. Point it at one image or a whole folder.

----------------------------------------------------------------
SETUP
----------------------------------------------------------------
Nothing to install. Everything this tool needs is already inside the
"bin" folder next to it. Just open Terminal and use it (below).

(Apple Silicon Mac only — M1/M2/M3/M4/M5. If you ever move this to an
Intel Mac it won't run; ask Molly for the Intel version.)

----------------------------------------------------------------
HOW TO USE IT
----------------------------------------------------------------
In Terminal, type the command below, then a SPACE, then DRAG the script
file (make-video) or the folder/image into the window so its path fills in.

  *** Whole folder, every image becomes a 3-hour video: ***

     bash "<drag make-video here>" "<drag your image folder here>" 3

  *** Just one image, 3-hour video: ***

     bash "<drag make-video here>" "<drag one image here>" 3

The number at the end is the length in HOURS (3 = 3 hours).
Fractions work too: 0.5 = 30 minutes, 0.0167 = about 1 minute (good for a test).

The finished .mp4 files appear right next to the original images.

----------------------------------------------------------------
OPTIONS (add to the end of the command)
----------------------------------------------------------------
  --zoom 4        Add a very slow, subtle zoom over the whole video.
                  (4 = 4%. Looks "alive" but barely noticeable.)
                  NOTE: this re-encodes every frame, so it is SLOW —
                  a 3-hour file takes ~1.5-2 hours instead of ~90 seconds.

  --out "/some/folder"   Put the .mp4 files in a specific folder instead
                         of next to the images.

  --jobs 4        How many to render at once. Leave it out — the tool
                  picks a good number for your Mac automatically.

Example: a folder of images, 3-hour videos, with the subtle zoom:

     bash "<drag make-video here>" "<drag folder here>" 3 --zoom 4

----------------------------------------------------------------
GOOD TO KNOW
----------------------------------------------------------------
- No zoom = FAST. A 3-hour 4K video is ready in about 90 seconds and is
  a few gigabytes. With --zoom it is much slower and the files are bigger
  (~34 GB for a 3-hour 4K file at high quality).

- Output is 4K, 30 fps, no audio, standard MP4 — uploads straight to YouTube.

- It skips anything that is not an image, and ignores the hidden "._" files
  macOS sometimes leaves on drives.

- See every option with:   bash "<drag make-video here>" --help
================================================================
