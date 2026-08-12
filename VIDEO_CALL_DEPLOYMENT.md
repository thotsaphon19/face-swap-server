# FaceSwap Mobile Camera -> Video Call Deployment

## Supported production route

The phone is the physical camera. Face swapping happens on the GPU server. A desktop computer receives the processed output and exposes it to webcam-capable software through OBS Virtual Camera.

This route supports both iOS and Android without root/jailbreak and avoids private camera hooks.

## 1. Deploy GPU worker (RunPod)

Use the existing `deploy/runpod_setup.sh`, provide your licensed face-swap model at the configured model path, and keep the pod running for calls. Verify `nvidia-smi`, `/health`, and `tools/check_install.py`.

## 2. Deploy gateway (DigitalOcean)

Set `PUBLIC_BASE_URL`, `SECRET_TOKEN`, `RUNPOD_BASE_URL`, and `RUNPOD_SECRET_TOKEN`, then run `deploy/digitalocean_setup.sh`.

Verify:

`https://YOUR_DOMAIN/health`

## 3. Install mobile app

### Android

`cd flutter_app`
`flutter clean`
`flutter pub get`
`flutter build apk --release`

Install `build/app/outputs/flutter-apk/app-release.apk`.

### iPhone

A Mac with Xcode and an Apple signing team is required.

`cd flutter_app`
`flutter clean`
`flutter pub get`
`cd ios && pod install && cd ..`
`flutter build ios --release`

Open `ios/Runner.xcworkspace` in Xcode, set Team/Bundle Identifier, connect the iPhone, and Run/Archive.

## 4. Start a FaceSwap session on the phone

1. Enter `https://YOUR_DOMAIN` and the app token.
2. Connect.
3. Select a source face that you have permission to use.
4. Start Stream.
5. Confirm `SRC READY`, `WS ON`, and a stable RTT.
6. Tap the desktop icon in the app bar to copy the Receiver URL.

## 5. Configure OBS on Windows/macOS

Create a Browser Source using the copied Receiver URL, fit it to a 1280x720 scene, and click Start Virtual Camera.

The backend sends processed frames to both the phone preview and desktop viewers. A slow desktop viewer is dropped so it cannot stall the phone-to-GPU inference stream.

## 6. Video-call application

Open the desktop version/browser experience of the target service and select `OBS Virtual Camera` where that service allows selecting a webcam. Keep microphone/audio handled by the call application on the computer; do not route call audio through the face-swap GPU.

## 7. Lip-sync / stability test

Before a real call, record 30 seconds from OBS Virtual Camera while speaking and clapping once. If visible mouth motion trails audio, inspect mobile RTT. The system intentionally drops stale frames, but network/GPU latency still exists.

Start with 480p/10-12 fps. Only increase settings after RTT remains stable.

## Important platform boundary

This package does not claim to register itself as a new camera inside LINE/Instagram/Facebook running on an unmodified iPhone or ordinary Android phone. iOS does not expose a public system-wide virtual-camera registration API for third-party iPhone apps, and Android support for system virtual cameras is device/system-privilege dependent. The cross-platform deployment route in this package is therefore mobile camera -> GPU -> desktop -> OBS Virtual Camera.
