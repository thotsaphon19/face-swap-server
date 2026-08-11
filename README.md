# face-swap-server

Repository contains:
- `backend/` — FastAPI backend (HTTP + WebSocket)
- `frontend/` — PWA simple web client
- `flutter_client/` — iVCam-style Flutter mobile client
- `Dockerfile`, `Dockerfile.gpu`, `docker-compose.yml`
- `deploy/` — nginx config and container startup script

---

## API Contract

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/health` | No | Liveness check |
| GET | `/connect` | No | Flutter client discovery; returns `status`, `ws_path`, `auth_required` |
| GET | `/session` | No | Model load status and device info |
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

---

## Quick start (local / DigitalOcean droplet)

```bash
cp .env.example .env
# Edit .env: set SECRET_TOKEN, RUNPOD_URL if needed
docker compose up -d --build
```

Verify:
```bash
curl http://localhost/health
curl http://localhost/connect
```

---

## Flutter client

Located in `flutter_client/`. Uses Material 3 dark theme with iVCam-style concentric rings UI.

### Build
```bash
cd flutter_client
flutter pub get
flutter run          # connected device / emulator
flutter build apk    # release APK
```

### Configure server URL
1. Launch the app
2. Tap the ⚙ (settings) icon in the top-right
3. Enter `http://<server-ip>` (e.g. `http://<your-droplet-ip>`)
4. Tap **Save & Connect**

The app calls `GET /connect` to verify the server is reachable, then displays the connection status with animated concentric rings.

---

## Runpod GPU deployment

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

---

## DigitalOcean deployment

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

---

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SECRET_TOKEN` | `testing123` | ****** for `/v1/process_frame` and WebSocket |
| `WORKER_PORT` | `8000` | uvicorn port (internal) |
| `MODEL_DIR` | `/workspace/model/checkpoints` | Path to model weights |
| `LOG_LEVEL` | `info` | Logging level |
| `RUNPOD_URL` | *(unset)* | Runpod GPU endpoint (for control-plane proxy use) |

---

## Notes
- Replace the dummy model loader in `backend/app.py` (`load_model()`) with your real model.
- For lower latency, WebRTC (aiortc/pion) is preferred over WebSocket frames; this repo uses WebSocket for simplicity.
- Docker CI pushes CPU image to `ghcr.io/thotsaphon19/face-swap-server:latest` on every push to `main`.