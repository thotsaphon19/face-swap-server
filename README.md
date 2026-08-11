# face-swap-server — MVP Camera-Streaming + Face-Swap System

> ⚠️ **ตรวจสอบก่อนใช้งานจริง**: ไฟล์นี้รวมเนื้อหาจาก 2 branch ที่มีรายละเอียดขัดแย้งกัน กรุณาเช็ค 2 จุดนี้กับโค้ดจริงก่อน commit:
> 1. Backend มี endpoint `/connect` และ `/session` จริงหรือไม่ (ดูใน `backend/app.py`)
> 2. มีไฟล์ `deploy/runpod_setup.sh` และ `deploy/digitalocean_setup.sh` จริงหรือไม่

## Overview

This repository implements a mobile-to-server camera-streaming and face-swap system:

```
[Flutter App (Android/iOS)]
          │ WebSocket binary frames (JPEG)
          ▼
[FastAPI Backend] ──▶ Face-Swap Model (GPU / CPU)
          │ processed JPEG frames
          ▼
[Flutter App displays swapped face]
```

### Repository structure

| Path | Purpose |
|------|---------|
| `backend/app.py` | FastAPI backend — HTTP REST + WebSocket binary frame handler |
| `frontend/` | PWA web client (existing, preserved) |
| `flutter_client/` | Flutter mobile app for Android / iOS |
| `deploy/` | Nginx config, Runpod & DigitalOcean setup scripts |
| `Dockerfile` | CPU production image |
| `Dockerfile.gpu` | GPU production image (CUDA) |
| `docker-compose.yml` | Docker Compose with optional `gpu` profile |

---

## 1 · Quick Start (local / Docker Compose)

```bash
# 1. Copy and edit environment
cp .env.example .env
# Edit SECRET_TOKEN, RUNPOD_URL if needed

# 2. Build & run (CPU mode)
docker compose up -d --build

# 3. Open PWA: http://localhost
# 4. Health check
curl http://localhost/health
curl http://localhost/connect
```

To run the GPU worker (requires NVIDIA Docker runtime):
```bash
docker compose --profile gpu up -d gpu_worker
```

### Notes
- For real-time low-latency, WebRTC (aiortc/pion) is preferred instead of WebSocket frames. This repo uses a WebSocket binary frame approach for simplicity.
- Replace the dummy model loader in `backend/app.py` (`load_model()`) with your real model loading & inference steps.

### GitHub Actions image publishing
- The `docker-image.yml` workflow publishes `latest` to Docker Hub (and/or `ghcr.io/thotsaphon19/face-swap-server:latest` — confirm which registry is actually configured).
- Configure these repository secrets before running the workflow:
  - `DOCKERHUB_USERNAME` : your Docker Hub username (namespace)
  - `DOCKERHUB_TOKEN` : Docker Hub access token with push permission

---

## 2 · Backend API

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/health` | No | Liveness check, returns device & model dir |
| GET | `/connect` | No | Flutter client discovery; returns `status`, `ws_path`, `auth_required` *(verify this exists)* |
| GET | `/session` | No | Model load status and device info *(verify this exists)* |
| POST | `/v1/process_frame` | ****** | Upload JPEG → returns processed JPEG |
| WS | `/ws?token=<token>` | Token in query | Binary JPEG frames in → processed JPEG bytes out |

### `/connect` response example
```json
{
  "status": "ready",
  "device": "cpu",
  "ws_path": "/ws",
  "process_path": "/v1/process_frame",
  "auth_required": true
}
```

### WebSocket protocol
- **Client → Server**: raw JPEG bytes
- **Server → Client**: raw JPEG bytes (processed / face-swapped)
- **Server → Client (error)**: JSON text `{"error": "..."}`

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SECRET_TOKEN` | `testing123` | ****** for auth (`/v1/process_frame` and WebSocket) |
| `WORKER_PORT` | `8000` | Port for uvicorn |
| `MODEL_DIR` | `/workspace/model/checkpoints` | Path to model checkpoint files |
| `LOG_LEVEL` | `info` | Python log level |
| `CORS_ORIGINS` | `*` | Comma-separated allowed origins |
| `RUNPOD_URL` | *(unset)* | Runpod GPU endpoint (for control-plane proxy use, if applicable) |

---

## 3 · Flutter App

### Requirements
- Flutter SDK ≥ 3.1 ([install guide](https://docs.flutter.dev/get-started/install))
- Android SDK (for APK build)
- Xcode 15+ (for iOS build)
- A physical device (camera access required on real hardware)

### Build & Install APK (Android)

```bash
cd flutter_client

# 1. Install dependencies
flutter pub get

# 2. Connect Android device (USB, enable developer mode + USB debugging)
#    OR start emulator: flutter emulators --launch <emulator_id>

# 3. Run in debug mode
flutter run

# 4. Build release APK
flutter build apk --release

# APK location:
# build/app/outputs/flutter-apk/app-release.apk

# 5. Install on connected device
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
3. Set **WebSocket URL** (e.g. `ws://192.168.1.100/ws` or `wss://your-domain.com/ws`) — or, if using `/connect` discovery, just enter `http://<server-ip>` and tap **Save & Connect**
4. Set **Auth Token** (must match `SECRET_TOKEN` on server)
5. Choose FPS (recommended: 8–15) and camera resolution
6. Tap **Save & Reconnect Camera**
7. Back on the main screen, tap **Connect Server**
8. Tap **Start Stream** — local preview left, face-swap result right

---

## 4 · Deployment: Runpod GPU

> Best for GPU inference (face-swap model). Pair with DigitalOcean for the web/WS proxy.

### Option A — using setup script (recommended if `deploy/runpod_setup.sh` exists)

```bash
# On a Runpod GPU pod (RTX 3090 / A5000 / A100):

git clone https://github.com/thotsaphon19/face-swap-server.git /workspace/face-swap-server
cd /workspace/face-swap-server

SECRET_TOKEN=your_secret_token bash deploy/runpod_setup.sh

# Upload model checkpoints
# scp ./your_model.pth root@<pod-ip>:/workspace/model/checkpoints/

curl http://localhost:8000/health
# {"status":"ok","device":"cuda","model_dir":"/workspace/model/checkpoints"}

# Expose via Runpod TCP proxy → port 8000
```

### Option B — manual build (if the setup script doesn't exist)

```bash
ssh <your-pod-id>@ssh.runpod.io -i ~/.ssh/id_ed25519

cd /workspace
git clone https://github.com/thotsaphon19/face-swap-server.git
cd face-swap-server

cp .env.example .env
# Edit .env as needed

docker build -f Dockerfile.gpu -t face-swap-gpu:latest .
docker run -d --name face-swap-gpu --restart unless-stopped \
  -p 8000:8000 --env-file .env face-swap-gpu:latest

curl http://127.0.0.1:8000/health
```

**Flutter WS URL for Runpod:**
```
ws://<RUNPOD_PUBLIC_HOST>:<TCP_PORT>/ws?token=your_secret_token
```

---

## 5 · Deployment: DigitalOcean (CPU / Proxy)

> Suitable for the web frontend + API proxy, or all-in-one CPU deployment for testing.

### Minimum spec
- Ubuntu 22.04, 2 vCPU, 4 GB RAM

### Option A — using setup script (recommended if `deploy/digitalocean_setup.sh` exists)

```bash
git clone https://github.com/thotsaphon19/face-swap-server.git /opt/face-swap-server
cd /opt/face-swap-server

SECRET_TOKEN=your_secret_token bash deploy/digitalocean_setup.sh

# (Optional) set DOMAIN for HTTPS
DOMAIN=yourdomain.com SECRET_TOKEN=your_secret_token \
    bash deploy/digitalocean_setup.sh

curl http://<DROPLET_IP>/health
curl http://<DROPLET_IP>/connect
```

### Option B — manual setup (if the setup script doesn't exist)

```bash
ssh root@<your-droplet-ip>

apt update && apt install -y git curl
curl -fsSL https://get.docker.com | sh

cd /opt
git clone https://github.com/thotsaphon19/face-swap-server.git
cd face-swap-server

cp .env.example .env
# Edit .env: set SECRET_TOKEN (and optionally RUNPOD_URL)

docker compose up -d --build
curl http://localhost/health
curl http://localhost/connect
```

Open firewall:
```bash
ufw allow OpenSSH
ufw allow 80
ufw allow 443
ufw --force enable
```

**Flutter WS URL for DigitalOcean:**
```
ws://<DROPLET_IP>/ws?token=your_secret_token
# or with HTTPS:
wss://yourdomain.com/ws?token=your_secret_token
```

---

## 6 · Staged Deployment Architecture

```
Phase 1 (test):
  [Flutter App] ──WS──▶ [DigitalOcean Nginx :443]
                                  │ proxy_pass
                                  ▼
                         [Runpod uvicorn :8000]
                                  │
                                  ▼
                         [GPU face-swap model]

Phase 2 (consolidate):
  [Flutter App] ──WS──▶ [Single Physical Server]
                         (GPU + Nginx + uvicorn)
```

For Phase 1, configure DigitalOcean Nginx to reverse-proxy to the Runpod public URL:

```nginx
location ~ ^/(v1|ws|health|connect|session)$ {
    proxy_pass http://<RUNPOD_HOST>:<TCP_PORT>;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
}
```

---

## 7 · Wiring in a Real Face-Swap Model

The dummy model in `backend/app.py` returns the original image unchanged. To use a real model:

```python
# backend/app.py — replace load_model():

def load_model():
    global _model
    if _model is not None:
        return _model
    import torch
    # Example: load a TorchScript or custom model
    _model = torch.jit.load(os.path.join(MODEL_DIR, "faceswap.pt"), map_location=DEVICE)
    _model.eval()
    logger.info(f"Loaded real model from {MODEL_DIR} on {DEVICE}")
    return _model
```

Then update the inference call in `process_frame` / `websocket_endpoint` accordingly.

---

## 8 · Smoke Test (End-to-End)

```bash
# 1. Start server (local Docker or remote)
docker compose up -d --build
curl http://localhost/health          # → {"status":"ok",...}

# 2. Test HTTP endpoint
curl -X POST http://localhost/v1/process_frame \
  -H "Authorization: ******" \
  -F "file=@/path/to/test.jpg" \
  --output result.jpg
# result.jpg should be a valid JPEG

# 3. Test WebSocket
python3 - <<'PY'
import asyncio, websockets, pathlib

async def test():
    url = "ws://localhost/ws?token=testing123"
    async with websockets.connect(url) as ws:
        data = pathlib.Path("/path/to/test.jpg").read_bytes()
        await ws.send(data)
        result = await ws.recv()
        pathlib.Path("/tmp/ws_result.jpg").write_bytes(result)
        print(f"Received {len(result)} bytes")

asyncio.run(test())
PY

# 4. Install Flutter APK and verify live streaming works end-to-end
```

---

## 9 · Notes & Recommendations

- **Latency**: WebSocket JPEG approach adds ~30–100 ms roundtrip on LAN. For sub-30 ms,
  consider replacing with WebRTC (aiortc on server).
- **Frame drop**: The Flutter app uses a "one frame at a time" strategy — it waits for the
  previous frame result before sending the next, preventing queue buildup.
- **Face-swap quality**: For smooth transitions add temporal smoothing in the model pipeline
  (blend previous output with current).
- **Security**: Change `SECRET_TOKEN` before any public deployment.
- **HTTPS**: Required on iOS for WebSocket (`wss://`). Set up via `DOMAIN=` in the DO script.