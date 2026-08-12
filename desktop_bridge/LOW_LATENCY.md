# Low-latency profile

Recommended first profile for real calls:

- Mobile camera: 480p / front camera
- Mobile target FPS: 10-12
- RunPod: persistent GPU pod, no cold start
- Face detector size: 256
- Output JPEG quality: 68-72
- OBS canvas: 1280x720, 30 fps
- OBS source: Browser Source only; no filters
- Network: phone on stable 5 GHz/6 GHz Wi-Fi; computer on Ethernet when possible

The mobile sender uses one-frame-in-flight backpressure. If round-trip latency rises, old frames are dropped rather than queued. This keeps mouth motion recent even if frame rate falls temporarily.

If RTT is consistently over ~180 ms, move the GPU closer to the user or reduce mobile FPS/resolution. Increasing FPS cannot fix high RTT and can make a queued design worse.
