# face-swap-server — MVP Camera-Streaming + Face-Swap System

Production-leaning MVP deploy setup for a mobile client → control plane/API → GPU inference flow.

## What is included

- **FastAPI backend** with:
  - `GET /health`
  - `GET /v1/client-config`
  - `POST /v1/sessions`
  - `GET /v1/sessions/{session_id}`
  - `POST /v1/sessions/{session_id}/start`
  - `POST /v1/sessions/{session_id}/stop`
  - `POST /v1/process_frame`
  - `WS /ws`
- **Two Flutter mobile clients**, each against a different API contract (see [Two Flutter clients in this repo](#two-flutter-clients-in-this-repo)):
  - `flutter_client/` — mirrors the `/v1/sessions` contract documented below
  - `mobile/` — an iVCam-inspired UI using a simplified, singular-session contract
- **Primary iVCam-style camera streaming app** in `flutter_app/` — connection-first mobile app for real-time face-swap streaming
- **PWA reference client** in `frontend/` showing the same contract `flutter_client/` uses
- **CPU Docker image** for the control plane
- **GPU Docker image** for local GPU or Runpod inference workers
- **docker-compose.yml** for:
  - local CPU-only smoke testing
  - local GPU worker profile
  - final single-machine deployment
- **Nginx reverse proxy** built into the control-plane container
- **Bootstrap script**: `deploy/bootstrap.sh`

The repository still uses a dummy inference model by default. Replace `load_model()` in `backend/app.py` with the real face-swap model load/inference path when ready.

## Architecture

### Fastest path before August 12

1. **Flutter/mobile app** (`flutter_client/`) captures JPEG frames and authenticates with `SECRET_TOKEN`
2. **DigitalOcean control plane** hosts:
   - static frontend/PWA
   - session + control endpoints
   - websocket ingress
   - HTTP frame ingress
3. **Runpod GPU worker** receives proxied `/v1/process_frame` and `/ws` traffic
4. **Processed JPEG output** returns to the mobile client

### Final single-machine path

Notes:
- For real-time low-latency, WebRTC (aiortc/pion) is preferred instead of WebSocket frames. This repo uses a WebSocket binary frame approach for simplicity.
- Replace the dummy model loader in backend/app.py with your real model loading & inference steps.

---

## Two Flutter clients in this repo

This repo currently ships **two separate Flutter apps against two separate API
contracts**. They are not interchangeable — pick the one that matches the
backend routes you're running, or keep both if you're intentionally maintaining
two client experiences.

---

## Flutter App — `flutter_app/` (Primary mobile camera streaming app)

`flutter_app/` is the **recommended mobile app** for real-time face-swap
streaming from a phone to the backend. It uses an iVCam-style connection-first
flow:

1. On launch, a **Connection Screen** loads the last-saved server URL and
   attempts to reach `GET /health` automatically.
2. Shows **Connecting / Connected / Failed** states clearly before enabling
   the camera.
3. Once connected, the **Camera Stream Screen** starts the camera and streams
   JPEG frames over WebSocket to the backend.
4. If the WebSocket drops, the app **auto-reconnects** (every 3 s) without
   stopping the camera preview.

### App roles

| Directory | Role |
|---|---|
| `flutter_app/` | **Primary** — iVCam-style camera streaming app (this section) |
| `flutter_client/` | Lightweight status/control app using `/v1/sessions` API |
| `mobile/` | Alternative iVCam-inspired UI using simplified `/v1/session` API |

### Prerequisites

- Flutter ≥ 3.10 and Dart ≥ 3.1  (`flutter --version`)
- Android SDK / Android Studio with a connected device or emulator (API 21+)
- A running backend instance (see Quick Start section)

### Quick start

```bash
cd flutter_app
flutter pub get
flutter run          # hot-reload on connected device/emulator
```

### Server URL format

Enter the HTTP base URL of your backend in the Connection Screen:

```
http://192.168.1.100          # local network
http://your-server.example.com
```

The app automatically:
- checks `http://SERVER/health` to verify connectivity
- connects the WebSocket at `ws://SERVER/ws` (or `wss://` for HTTPS)

### Auth token

Set the `SECRET_TOKEN` from your server's `.env` in the **Auth Token** field.
Leave blank if the server runs without a token.

### Build release APK (Android)

```bash
cd flutter_app
flutter pub get
flutter build apk --release
# APK output: flutter_app/build/app/outputs/flutter-apk/app-release.apk
```

Transfer the APK to your device with `adb` or copy it manually:

```bash
adb install build/app/outputs/flutter-apk/app-release.apk
```

### Build for iOS

```bash
cd flutter_app
flutter pub get
flutter build ios --release
```

Open `flutter_app/ios/Runner.xcworkspace` in Xcode to archive and deploy.

---

| | `flutter_client/` | `mobile/` |
|---|---|---|
| Style | Matches the documented `/v1/sessions` control-plane API below | iVCam-inspired home screen, simplified singular-session API |
| Session create | `POST /v1/sessions` | `POST /v1/session` |
| Session fetch | `GET /v1/sessions/{session_id}` | `GET /v1/session/:id` |
| Session end | `POST /v1/sessions/{session_id}/stop` | `DELETE /v1/session/:id` |
| Discovery/health | `GET /v1/client-config` | `GET /v1/info` |

If your backend only implements the `/v1/sessions/...` routes documented in
this README, the `mobile/` client's `/v1/session`, `/v1/info`, and `DELETE`
endpoints will 404 until equivalent routes are added to `backend/app.py`.

## Flutter Mobile App — `mobile/` (iVCam-style client)

The `mobile/` directory contains a Flutter app that provides an iVCam-inspired
home screen for searching, connecting to, and monitoring the face-swap backend.
It targets a simplified, singular-session variant of the API (see table above).

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

### Backend API contract (used by the `mobile/` Flutter app — NOT the same as `flutter_client/`)

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/health` | — | Liveness check |
| GET | `/v1/info` | — | Server IP, hostname, device |
| POST | `/v1/session` | required | Create a session → `{session_id}` |
| GET | `/v1/session/:id` | required | Session details |
| DELETE | `/v1/session/:id` | required | End session |
| POST | `/v1/process_frame` | required | Process a JPEG frame |
| WS | `/ws?token=…` | query | Streaming frame processing |

### Running the Flutter tests

```bash
cd mobile
flutter test
```

---

## Flutter Mobile App — `flutter_client/`

Use the same compose stack with the `local-gpu` profile:

- `control-plane` container serves Nginx + FastAPI
- `gpu-worker` container runs the CUDA/PyTorch worker locally
- set `RUNPOD_BASE_URL=http://gpu-worker:8000`

That gives the same control-plane flow you test on DigitalOcean + Runpod, but collapsed onto one RTX 5060 server.

## Repository structure

| Path | Purpose |
|------|---------|
| `backend/app.py` | FastAPI backend — session API, HTTP REST + WebSocket binary frame handler |
| `frontend/` | PWA reference web client |
| `flutter_client/` | Flutter mobile app for Android / iOS, `/v1/sessions` contract (package: `face_swap_client`) |
| `mobile/` | Flutter mobile app for Android / iOS, simplified `/v1/session` contract (iVCam-style UI) |
| `deploy/` | Nginx config + `bootstrap.sh` setup script |
| `Dockerfile` | CPU production image (control plane) |
| `Dockerfile.gpu` | GPU production image (CUDA, inference worker) |
| `docker-compose.yml` | Docker Compose with `local-gpu` profile |

## Environment variables

Copy `.env.example` to `.env` and update:

| Variable | Required | Purpose |
| --- | --- | --- |
| `APP_ROLE` | yes | `control-plane` or `inference` |
| `ENABLE_NGINX` | yes | `true` for public ingress container, `false` for worker-only |
| `PUBLIC_BASE_URL` | yes | Public base URL used in generated session/client URLs |
| `SECRET_TOKEN` | yes | required for clients |
| `RUNPOD_SECRET_TOKEN` | yes | Token used between control plane and GPU worker |
| `RUNPOD_BASE_URL` | no | Empty for local CPU test, Runpod URL or `http://gpu-worker:8000` otherwise |
| `MODEL_DIR` | yes | Where models are mounted |
| `REQUEST_TIMEOUT_SECONDS` | yes | Timeout when proxying to Runpod |
| `SESSION_TTL_SECONDS` | yes | In-memory session lifetime |
| `MAX_IMAGE_BYTES` | yes | Upload/frame size guard |
| `CORS_ORIGINS` | yes | Comma-separated allowed origins |

## Flutter/mobile client

The Flutter app lives in `flutter_client/` (package name `face_swap_client`). It mirrors the contract below — the same one the reference PWA in `frontend/` uses.

### Build & Install APK (Android)

```bash
cd flutter_client
flutter pub get
flutter run                    # debug, connected device / emulator
flutter build apk --release    # release APK

# APK location:
# build/app/outputs/flutter-apk/app-release.apk
flutter install
```

### Build for iOS

```bash
cd flutter_client
flutter pub get
open ios/Runner.xcworkspace   # set signing in Xcode
flutter build ios --release
```

### App usage
1. Launch the app on your phone
2. Tap the ⚙️ **Settings** icon
3. Set the server base URL (e.g. `http://<server-ip>` or `https://your-domain.com`)
4. Set **Auth Token** (must match `SECRET_TOKEN` on the server)
5. Tap **Save & Connect** — the app calls `GET /v1/client-config` to discover URLs, then creates a session via `POST /v1/sessions`
6. Choose FPS (recommended: 6–10) and camera resolution
7. Tap **Start Stream** — local preview left, face-swap result right

### 1. Discover config

`GET /v1/client-config`

Example response:

```json
{
  "role": "control-plane",
  "http_process_url": "https://your-domain/v1/process_frame",
  "session_create_url": "https://your-domain/v1/sessions",
  "ws_url": "wss://your-domain/ws",
  "requires_bearer_token": true,
  "binary_frame_format": "jpeg-bytes",
  "max_image_bytes": 5242880,
  "session_ttl_seconds": 3600
}
```

### 2. Create + manage a session

`POST /v1/sessions` with `Authorization: <bearer token>`

Example body:

```json
{
  "client_name": "flutter-app",
  "transport": "ws",
  "resolution": "640x480",
  "fps": 8,
  "metadata": {
    "platform": "android"
  }
}
```

Example response:

```json
{
  "session_id": "f8d3...",
  "status": "created",
  "created_at": "2026-08-11T00:00:00Z",
  "updated_at": "2026-08-11T00:00:00Z",
  "expires_at": "2026-08-11T01:00:00Z",
  "transport": "ws",
  "client_name": "flutter-app",
  "resolution": "640x480",
  "fps": 8,
  "ws_url": "wss://your-domain/ws?session_id=f8d3...",
  "process_frame_url": "https://your-domain/v1/process_frame",
  "stop_url": "https://your-domain/v1/sessions/f8d3.../stop",
  "metadata": {
    "platform": "android"
  }
}
```

Then call:

- `POST /v1/sessions/{session_id}/start`
- `POST /v1/sessions/{session_id}/stop`
- `GET /v1/sessions/{session_id}`

### 3. Send inference frames

#### HTTP mode

`POST /v1/process_frame`

- Header: `Authorization: <bearer token>`
- Optional header: `X-Session-Id: <session_id>`
- Body: `multipart/form-data` with `file=<jpeg>`

Success:

- `200 OK`
- `Content-Type: image/jpeg`
- header `X-Process-Time-Ms`

#### WebSocket mode

Connect to the `ws_url` returned by the session API, then add the same client token as the `token` query parameter.

- client → server: raw JPEG bytes
- server → client: raw JPEG bytes
- server → client on recoverable errors: JSON text such as `{"error":"Invalid image"}`

## Local test environment

### CPU-only smoke test

```bash
cp .env.example .env
./deploy/bootstrap.sh
```

Then open `http://localhost/`.

Recommended local `.env` values:

```env
PUBLIC_BASE_URL=http://localhost
SECRET_TOKEN=testing123
RUNPOD_SECRET_TOKEN=testing123
RUNPOD_BASE_URL=
```

This runs local dummy inference inside the control-plane container, so it works even without a GPU.

### Local GPU worker test

Use this when you want to test the split control-plane → GPU-worker path on one machine.

```env
PUBLIC_BASE_URL=http://localhost
SECRET_TOKEN=testing123
RUNPOD_SECRET_TOKEN=testing123
RUNPOD_BASE_URL=http://gpu-worker:8000
```

Start:

```bash
./deploy/bootstrap.sh local-gpu
```

## DigitalOcean deployment

Use the CPU image/container as the public entrypoint.

### 1. Provision the droplet

- Ubuntu 22.04+
- Open ports `80` and `443`
- Install Docker Engine + Compose plugin

### 2. Copy project and env file

```bash
scp -r . root@YOUR_DROPLET_IP:/opt/face-swap-server
ssh root@YOUR_DROPLET_IP
cd /opt/face-swap-server
cp .env.example .env
```

Set at minimum:

```env
PUBLIC_BASE_URL=https://api.your-domain.com
SECRET_TOKEN=<strong-public-token>
RUNPOD_SECRET_TOKEN=<strong-internal-token>
RUNPOD_BASE_URL=https://YOUR_RUNPOD_ENDPOINT
```

### 3. Start the control plane

```bash
docker compose up -d --build control-plane
```

### 4. Put TLS in front

Use your existing preferred TLS layer:

- DigitalOcean Load Balancer
- Caddy
- Nginx + certbot

This repo only provides the app-side Nginx config on port `80`, so TLS termination can stay outside the container.

## Runpod GPU deployment

Use `Dockerfile.gpu` for the worker image.

### 1. Build and push

```bash
docker build -f Dockerfile.gpu -t ghcr.io/YOUR_ORG/face-swap-server:gpu-latest .
docker push ghcr.io/YOUR_ORG/face-swap-server:gpu-latest
```

### 2. Create the Runpod pod

Set environment variables:

```env
APP_ROLE=inference
ENABLE_NGINX=false
WORKER_PORT=8000
SECRET_TOKEN=<same as RUNPOD_SECRET_TOKEN on DigitalOcean>
RUNPOD_SECRET_TOKEN=<same value>
MODEL_DIR=/workspace/model/checkpoints
LOG_LEVEL=INFO
PUBLIC_BASE_URL=https://YOUR_RUNPOD_ENDPOINT
```

Mount or upload your model files into:

```text
/workspace/model/checkpoints
```

Expose container port `8000`.

### 3. Smoke test the pod

```bash
curl http://YOUR_RUNPOD_ENDPOINT/health
```

Expected output includes:

```json
{
  "status": "ok",
  "role": "inference"
}
```

## Final single-machine RTX 5060 deployment

On the real server:

1. Install Docker + Compose
2. Copy the repo
3. Put the real models under `./model/checkpoints`
4. Set:

```env
PUBLIC_BASE_URL=https://faceswap.your-domain.com
SECRET_TOKEN=<strong-public-token>
RUNPOD_SECRET_TOKEN=<same-or-separate-internal-token>
RUNPOD_BASE_URL=http://gpu-worker:8000
```

5. Start:

```bash
cd /opt/face-swap-server
./deploy/bootstrap.sh local-gpu
```

This reproduces the same split architecture locally, so the migration from DigitalOcean + Runpod is just an env/config change.

## Operational notes

- **Auth**: change both tokens before public testing
- **Uploads**: default max frame size is 5 MB
- **Latency**: start at `320x240` or `640x480` and `6-10 fps`
- **Session storage**: in-memory only for now; restart clears sessions
- **Inference**: replace the dummy model with the real face-swap pipeline before public rollout
- **Frame drop**: prefer a "one frame at a time" client strategy — wait for the previous frame result before sending the next, to avoid queue buildup
- **HTTPS**: required on iOS for WebSocket (`wss://`) — terminate TLS in front of the control plane (see DigitalOcean deployment section)

## Useful commands

```bash
# Validate compose
docker compose config

# Follow logs
docker compose logs -f control-plane
docker compose logs -f gpu-worker

# Stop everything
docker compose down
```

## Production Face Swap Camera — `flutter_app/`

`flutter_app/` is the primary mobile camera client. It now supports selecting a source-face photo, sending it once over WebSocket, then streaming target camera JPEG frames to the GPU worker. The backend returns swapped JPEG frames.

### Architecture

```text
Flutter camera -> WSS -> DigitalOcean FastAPI -> WSS -> RunPod GPU -> FaceSwapEngine -> WSS -> Flutter
```

### Real model requirements

The repository no longer treats `DummyModel` as the production inference path. The GPU worker uses `backend/faceswap_engine.py` and expects an operator-supplied, properly licensed face-swap model at:

```text
/workspace/model/checkpoints/inswapper_128.onnx
```

It also uses InsightFace face analysis. InsightFace's current repository states that its code is MIT-licensed, while released model files/training data have separate licensing terms; its current README specifically directs users to contact InsightFace for licensing of the inswapper series and recognition models. Obtain the appropriate commercial/production licenses before deploying a paid/public service.

### RunPod

```bash
cd /workspace/face-swap-server
bash deploy/runpod_setup.sh
```

Then place the licensed model at:

```text
/workspace/model/checkpoints/inswapper_128.onnx
```

Test:

```bash
curl http://127.0.0.1:8000/health
curl -H "Authorization: Bearer $SECRET_TOKEN" http://127.0.0.1:8000/v1/gpu/status
```

The RunPod environment must use:

```env
APP_ROLE=inference
SECRET_TOKEN=<gpu-worker-token>
MODEL_DIR=/workspace/model/checkpoints
INSWAPPER_MODEL=inswapper_128.onnx
FACE_ANALYSIS_NAME=buffalo_l
FACE_DET_SIZE=320
```

### Flutter

```bash
cd flutter_app
flutter pub get
flutter run
```

Enter the DigitalOcean API URL, for example:

```text
https://api.example.com
```

and the public client token. The app converts it to `wss://api.example.com/ws` automatically.

After connecting:

1. Tap the photo icon and choose the source face.
2. Wait for `SRC READY`.
3. Tap `Start Stream`.
4. The top camera is the original camera preview; the bottom pane is the GPU face-swap result.

### Important realtime tuning

The default client target is 8 FPS and medium resolution. The app throttles frame capture to the selected FPS and keeps only one frame in flight, preventing a growing latency queue. Increase FPS only after measuring GPU/network latency.

### LINE / Instagram / Facebook

This Flutter app can provide a realtime swapped-camera preview. It does **not** automatically become a system-wide virtual camera for other apps. Android's CameraX/Camera2 APIs are appropriate for the native camera pipeline, but whether another app such as LINE or Instagram can select an app-produced virtual camera is controlled by the OS/app and cannot be guaranteed by Flutter alone. For direct use inside third-party video calls, an additional Android native camera-output/virtual-camera implementation is required and iOS has stricter platform/app constraints.

## Production FaceSwap Camera

Use `flutter_app/` as the only mobile client. The production path is:

Flutter camera -> WSS -> DigitalOcean FastAPI -> RunPod GPU -> InsightFace/ONNX -> WSS -> Flutter preview.

### Required environment

Control plane (`.env`):

```env
APP_ROLE=control-plane
PUBLIC_BASE_URL=https://api.example.com
SECRET_TOKEN=<long-random-public-token>
RUNPOD_BASE_URL=https://<runpod-public-https-endpoint>
RUNPOD_SECRET_TOKEN=<long-random-worker-token>
CORS_ORIGINS=https://app.example.com
```

GPU worker (`.env`):

```env
APP_ROLE=inference
SECRET_TOKEN=<long-random-worker-token>
MODEL_DIR=/workspace/model/checkpoints
INSWAPPER_MODEL=inswapper_128.onnx
FACE_ANALYSIS_NAME=buffalo_l
FACE_DET_SIZE=320
```

Place the operator-licensed `inswapper_128.onnx` at `$MODEL_DIR` before starting the worker.

### Flutter

```bash
cd flutter_app
flutter pub get
flutter run --release
# Android release bundle:
flutter build appbundle --release
```

Set the server URL in the app to `https://api.example.com`. The app converts it to `wss://api.example.com/ws` and keeps a per-run session ID.

### Important LINE / Instagram / Facebook limitation

This app provides a real-time processed camera preview inside the Flutter app. A normal Android/iOS third-party app cannot register an arbitrary software-generated video stream as a new system camera that every other app (such as LINE or Instagram) can select. CameraX/Camera2 provide camera capture and processing APIs, but they do not provide a public API for registering a new system-wide virtual camera device.

Therefore this build does **not** falsely claim that LINE/Instagram will see “FaceSwap Cam” as a selectable camera. To achieve that exact behavior requires an OS-level camera/virtual-camera implementation (for example a custom Android OS/HAL path, a rooted/custom-ROM solution, or an external computer virtual-camera bridge). The same limitation applies to iOS with additional platform restrictions.

## Production video-call path (iPhone + Android)

For a cross-platform setup that can be selected as a webcam by desktop calling software, use the mobile app as the physical camera and the included OBS Desktop Bridge as the virtual-camera endpoint:

`iPhone/Android -> FaceSwap GPU -> /viewer -> OBS Browser Source -> OBS Virtual Camera -> calling app`

See `VIDEO_CALL_DEPLOYMENT.md` and `desktop_bridge/README.md`.
