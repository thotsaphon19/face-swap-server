# FaceSwap Desktop Bridge (OBS Virtual Camera)

This bridge deliberately uses OBS Virtual Camera instead of a custom kernel/OS camera driver.
That makes the same workflow usable on Windows and macOS and lets the phone remain the camera source.

## Data path

Phone (iOS/Android) -> FaceSwap API/RunPod -> `/ws/viewer` -> OBS Browser Source -> OBS Virtual Camera -> video-call app.

## Receiver URL

The Flutter app has a desktop icon in the top bar. It copies a URL like:

`https://api.example.com/viewer?session_id=...&token=...`

Do not share this URL publicly because it contains the session credential.

## OBS setup

1. Install the current OBS Studio for your operating system.
2. Create a Scene named `FaceSwap Camera`.
3. Add **Browser Source** named `FaceSwap Receiver`.
4. Paste the receiver URL copied by the mobile app.
5. Set Width 1280 and Height 720. Tick `Shutdown source when not visible` OFF.
6. Fit the source to the canvas (`Transform -> Fit to screen`).
7. In OBS Controls click **Start Virtual Camera**.
8. Open the video-call app and select **OBS Virtual Camera** as the camera.

For lowest latency, do not add OBS video filters, scaling filters, or recording while calling.
Set OBS canvas/output to 1280x720 and 30 fps; the source itself may update at 8-15 fps depending on network/GPU latency.

## Test before a real call

Open the receiver URL in Chrome/Safari on the computer first. It must show `LIVE` and the swapped face.
Then test OBS Virtual Camera with a webcam test page or a local camera app before opening LINE/Messenger/etc.
