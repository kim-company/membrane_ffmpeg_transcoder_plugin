# Test fixtures

- `av-sync-test.ts`: three seconds of H.264 (1280x720, 30 fps) and AAC. Used for
  stream copy, mixed copy/encode, Opus, and the full video/audio quality ladder.
- `subtitle-test.ts`: teletext page 777, including the three expected German cues.
- `scte35-test.ts`: splice inserts for event 100 at 60 and 120 seconds and event
  101 at 180 seconds. FFmpeg processes this sparse timeline without real-time pacing.

The short audio/video fixture was copied without re-encoding from the original
fixture in commit `8716c468c81445ed7febeab0dd89b966655f68bb`:

```sh
git show 8716c468:test/data/av-sync-test.ts > /tmp/av-sync-original.ts
ffmpeg -v error -i /tmp/av-sync-original.ts -map 0:v -map 0:a -t 3 -c copy \
  -f mpegts -y test/data/av-sync-test.ts
```
