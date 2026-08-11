# face-swap-server — MVP Camera-Streaming + Face-Swap System

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
| `flutter_app/` | **NEW** Flutter mobile app for Android / iOS |
| `deploy/` | Nginx config, Runpod & DigitalOcean setup scripts |
| `Dockerfile` | CPU production image |
| `Dockerfile.gpu` | GPU production image (CUDA) |
| `docker-compose.yml` | Docker Compose with optional `gpu` profile |

---

## 1 · Quick Start (local / Docker Compose)

```bash
# 1. Copy and edit environment
cp .env.example .env
# Edit SECRET_TOKEN, etc.

# 2. Build & run (CPU mode)
docker compose up -d --build

# 3. Open PWA: http://localhost
# 4. Health check
curl http://localhost/health
```

To run the GPU worker (requires NVIDIA Docker runtime):
```bash
docker compose --profile gpu up -d gpu_worker
```

---

## 2 · Backend API

| Endpoint | Method | Auth | Description |
|----------|--------|------|-------------|
| `/health` | GET | none | Liveness check, returns device & model dir |
| `/v1/process_frame` | POST (multipart) | ****** | Single JPEG frame → returns processed JPEG |
| `/ws?token=TOKEN` | WebSocket | query param | Bidirectional binary frame stream |

### WebSocket protocol
- **Client → Server**: raw JPEG bytes
- **Server → Client**: raw JPEG bytes (processed / face-swapped)
- **Server → Client (error)**: JSON text `{"error": "..."}`

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SECRET_TOKEN` | `testing123` | ****** for auth |
| `WORKER_PORT` | `8000` | Port for uvicorn |
| `MODEL_DIR` | `/workspace/model/checkpoints` | Path to model checkpoint files |
| `LOG_LEVEL` | `INFO` | Python log level |
| `CORS_ORIGINS` | `*` | Comma-separated allowed origins |

---

## 3 · Flutter App

### Requirements
- Flutter SDK ≥ 3.1 ([install guide](https://docs.flutter.dev/get-started/install))
- Android SDK (for APK build)
- Xcode 15+ (for iOS build)
- A physical device (camera access required on real hardware)

### Build & Install APK (Android)

```bash
cd flutter_app

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
cd flutter_app
flutter pub get
open ios/Runner.xcworkspace   # set signing in Xcode
flutter build ios --release
```

### App usage
1. Launch **FaceSwap Cam** on your phone
2. Tap the ⚙️ **Settings** icon
3. Set **WebSocket URL** (e.g. `ws://192.168.1.100/ws` or `wss://your-domain.com/ws`)
4. Set **Auth Token** (must match `SECRET_TOKEN` on server)
5. Choose FPS (recommended: 8–15) and camera resolution
6. Tap **Save & Reconnect Camera**
7. Back on the main screen, tap **Connect Server**
8. Tap **Start Stream** — local preview left, face-swap result right

---

## 4 · Deployment: Runpod GPU

> Best for GPU inference (face-swap model). Pair with DigitalOcean for the web/WS proxy.

### Steps

```bash
# On a Runpod GPU pod (RTX 3090 / A5000 / A100):

# 1. Clone repo
git clone https://github.com/thotsaphon19/face-swap-server.git /workspace/face-swap-server
cd /workspace/face-swap-server

# 2. Run setup script
SECRET_TOKEN=your_secret_token bash deploy/runpod_setup.sh

# 3. Upload model checkpoints
# scp ./your_model.pth root@<pod-ip>:/workspace/model/checkpoints/

# 4. Test health
curl http://localhost:8000/health
# {"status":"ok","device":"cuda","model_dir":"/workspace/model/checkpoints"}

# 5. Expose via Runpod TCP proxy → port 8000
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

### Steps

```bash
# On the DigitalOcean droplet (as root):

# 1. Clone repo
git clone https://github.com/thotsaphon19/face-swap-server.git /opt/face-swap-server

# 2. Run setup script
SECRET_TOKEN=your_secret_token bash /opt/face-swap-server/deploy/digitalocean_setup.sh

# 3. (Optional) set DOMAIN for HTTPS
DOMAIN=yourdomain.com SECRET_TOKEN=your_secret_token \
    bash /opt/face-swap-server/deploy/digitalocean_setup.sh

# 4. Verify
curl http://<DROPLET_IP>/health
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
location ~ ^/(v1|ws|health) {
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
