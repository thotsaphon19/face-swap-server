# face-swap-server

Repository contains:
- backend/ : FastAPI backend (HTTP + WebSocket)
- frontend/ : PWA simple client
- Dockerfile, Dockerfile.gpu, docker-compose.yml
- deploy/ : nginx config and startup script

Quick start (local / DO droplet CPU)
1. Build and run with docker-compose:
   docker compose up -d --build

2. Place model files (if any) under ./model/checkpoints (or change MODEL_DIR)

3. Open http://<server-ip>/ and use the PWA frontend (set WS URL to wss://<server>/ws or ws://)

Runpod GPU deployment (recommended)
1. Use Runpod GPU template (RTX 3090). You can either:
   - Use the provided image and run manual install (install torch cu130 inside pod), or
   - Build Dockerfile.gpu and push to a registry, then use that image in Runpod (if Runpod accepts custom images).

2. On the GPU pod:
   - Ensure CUDA drivers present (nvidia-smi should show CUDA 13.0)
   - Install Python deps and PyTorch (cu130) if not baked into image:
     python -m pip install --index-url https://download.pytorch.org/whl/cu130 --upgrade torch torchvision torchaudio
     pip install -r backend/requirements.txt

3. Upload model files to /workspace/model/checkpoints on the pod (scp or wget)

4. Start uvicorn:
   . .venv/bin/activate
   uvicorn app:app --host 0.0.0.0 --port 8000

Notes:
- For real-time low-latency, WebRTC (aiortc/pion) is preferred instead of WebSocket frames. This repo uses a WebSocket binary frame approach for simplicity.
- Replace the dummy model loader in backend/app.py with your real model loading & inference steps.
---

## Flutter Mobile App (iVCam-style client)

The `mobile/` directory contains a Flutter app that provides an iVCam-inspired
home screen for searching, connecting to, and monitoring the face-swap backend.

### Prerequisites
- Flutter ≥ 3.10 (`flutter --version`)
- A running instance of the backend (see Quick Start above)

### Setup

```bash
cd mobile
flutter pub get
```

Configure the server URL and API token in the app's Settings screen (top-right
gear icon) or edit `mobile/lib/screens/settings_screen.dart`:

```
Default server URL : http://192.168.1.49:8000
Default API token  : testing123   (matches SECRET_TOKEN in .env)
```

### Run on a device / emulator

```bash
cd mobile
flutter run
```

### Build release APK

```bash
cd mobile
flutter build apk --release
# Output: mobile/build/app/outputs/flutter-apk/app-release.apk
```

### Connection flow

1. App starts → begins health-check polling (`GET /v1/info`) every 5 s.
2. When the server responds, the IP and device info are shown on screen.
3. Tap the phone icon (or **Connect** button) → `POST /v1/session` creates a
   session; the app moves to *Connected* state.
4. Tap **Disconnect** or **Refresh** to end the session (`DELETE /v1/session/:id`).
5. Settings screen lets you change the server URL and token; saved to device
   storage via `shared_preferences`.

### Backend API contract (used by the Flutter app)

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/health` | — | Liveness check |
| GET | `/v1/info` | — | Server IP, hostname, device |
| POST | `/v1/session` | ****** Create a session → `{session_id}` |
| GET | `/v1/session/:id` | ****** Session details |
| DELETE | `/v1/session/:id` | ****** End session |
| POST | `/v1/process_frame` | ****** Process a JPEG frame |
| WS | `/ws?token=…` | query | Streaming frame processing |

### Running the Flutter tests

```bash
cd mobile
flutter test
```
