# v5 Stability Release

- Session target-face tracking using IoU + center continuity.
- No stale-face paste when detection is lost.
- No temporal smoothing of mouth landmarks (avoids articulation lag).
- Mobile adaptive FPS / JPEG / resolution based on measured RTT.
- 1.4 s stale-frame watchdog forces a clean reconnect instead of queue growth.
- Exponential reconnect backoff with jitter.
- GPU `frame_meta` timing is shown separately from end-to-end RTT.
- Mobile UI shows RTT, GPU time, encode time, and dropped-frame count.
- OBS/Desktop `/viewer` changed to latest-frame-only canvas decoding.
- Flutter app version bumped to 1.2.0+5.
