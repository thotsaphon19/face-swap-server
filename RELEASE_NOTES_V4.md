# Production v4 — Cross-platform Video Call Bridge

Changes from v3:

- Removed Android privileged/system-camera path from the main mobile app.
- One Flutter mobile path for iOS and Android.
- Added `/viewer` receiver page and `/ws/viewer` subscriber endpoint.
- Processed frames are fanned out to the mobile preview and desktop receiver.
- Desktop receiver is isolated from the inference path: slow receivers are dropped instead of stalling GPU/mobile streaming.
- Mobile app can copy the OBS/Desktop receiver URL from the desktop icon.
- Added Windows/macOS OBS bridge instructions and receiver helper launchers.
- Added end-to-end video-call deployment and low-latency tuning guide.

Validated in this build environment:

- Python modules compile.
- Backend imports and `/viewer` route is registered.
- Processed-frame broadcaster unit smoke test passes.
- Deployment shell scripts parse with `bash -n`.

Not validated in this build environment:

- Physical iPhone/Android camera runtime.
- Xcode/IPA signing.
- Android release APK compilation (Flutter SDK not installed here).
- Real RunPod NVIDIA inference.
- A specific third-party calling application's acceptance of OBS Virtual Camera; that must be checked on the target desktop app/version.
