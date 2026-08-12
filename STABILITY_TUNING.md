# FaceSwap Camera v5 — Stability / Low-Latency Tuning

## What v5 changes

v5 keeps a strict **one-frame-in-flight** pipeline. A frame that has not returned
within 1.4 seconds is considered unusable for a call: the mobile client rebuilds
the WebSocket instead of continuing to queue stale video.

The mobile encoder adapts automatically:

- RTT <= 120 ms: configured FPS, max long edge 720, JPEG quality 70.
- RTT 120–180 ms: 10 FPS, max long edge 640.
- RTT 180–260 ms: 8 FPS.
- RTT > 260 ms: 6 FPS, max long edge 512, JPEG quality 55.

The result is intentionally latency-first. Under congestion you may see fewer
frames, but the mouth remains on the newest available camera frame instead of
falling seconds behind.

## Face stability

The GPU worker now keeps a target-face track per logical session. It uses
bounding-box IoU and normalized center distance to select the same person from
frame to frame. It does **not** temporally smooth the detected mouth landmarks,
because doing that makes speech articulation visibly late.

If detection is lost, the worker returns the current original frame rather than
pasting the last swapped crop. This avoids the classic "floating face" artifact.

Environment controls:

```env
TRACK_IOU_THRESHOLD=0.12
TRACK_CENTER_THRESHOLD=0.38
TRACK_MAX_MISSES=3
FACE_DET_SIZE=256
OUTPUT_JPEG_QUALITY=72
OPENCV_THREADS=1
```

For a single-person selfie camera, keep `TRACK_MAX_MISSES` between 2 and 4.
Increasing it does not hold the old face on screen; it only keeps target identity
history for reacquisition.

## OBS / Desktop receiver

The `/viewer` receiver uses a canvas and a single latest-frame decode slot.
If a newer JPEG arrives while Chromium/OBS is decoding, the pending frame is
replaced. This prevents Browser Source decode queues from creating extra delay.

Recommended OBS Browser Source:

- 1280x720 canvas
- 30 FPS OBS output (the camera stream may be 8–15 FPS)
- Shutdown source when not visible: OFF
- Refresh browser when scene becomes active: OFF

## Practical targets

For natural conversation, target these *measured* values in the Flutter status
bar:

- ENC <= 30 ms
- GPU <= 60 ms
- RTT <= 150 ms
- No repeated reconnects

A server-side face swap can never guarantee zero delay. If RTT is persistently
above 180–200 ms, move the GPU closer to the user before increasing FPS.

## Lip sync with the call microphone

The visual expression is taken from the live target frame, so the swapped mouth
follows the user's current mouth shape. However, LINE/Messenger may use a live PC
microphone while the video has network+GPU delay. If exact audio/video sync is
required, route microphone audio through a virtual audio device and add a delay
approximately equal to the measured video path latency. Calibrate with a clap
recording; do not guess a fixed value for every network.

## Production checks before a real call

1. `/health` returns `status=ok`.
2. `tools/check_install.py` reports CUDA provider on the inference worker.
3. Flutter shows `SRC READY`, `WS ON`.
4. GPU time stays stable for 60 seconds.
5. Walk partly out of frame and back: face must not remain floating off-head.
6. Put a second person briefly in frame: swap target must stay on the original
   tracked person.
7. Switch Wi‑Fi off/on: the app must reconnect and resend the source face.
8. Leave the stream running for at least 20 minutes before production use.
