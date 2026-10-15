# Local video fixture

`local-video.mp4` is a two-second, 32×32 solid-color H.264/yuv420p clip with no audio. It contains no external content. The WebKit navigation gate copies it into an owned temporary directory; no encoder is required to run the gate.

Generated with:

```sh
ffmpeg -f lavfi -i 'color=c=0x406080:s=32x32:d=2:r=2' \
  -c:v libx264 -pix_fmt yuv420p -movflags +faststart local-video.mp4
```
