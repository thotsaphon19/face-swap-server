# face-swap-server

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
- **PWA reference client** in `frontend/` showing the same contract a Flutter app should use
- **CPU Docker image** for the control plane
- **GPU Docker image** for local GPU or Runpod inference workers
- **docker-compose.yml** for:
  - local CPU-only smoke testing
  - local GPU worker profile
  - final single-machine deployment
- **Nginx reverse proxy** built into the control-plane container
- **Bootstrap script**: `deploy/bootstrap.sh`

The repository still uses a dummy inference model by default. Replace `load_model()` in `/home/runner/work/face-swap-server/face-swap-server/backend/app.py` with the real face-swap model load/inference path when ready.

## Architecture

### Fastest path before August 12

1. **Flutter/mobile app** captures JPEG frames and authenticates with `SECRET_TOKEN`
2. **DigitalOcean control plane** hosts:
   - static frontend/PWA
   - session + control endpoints
   - websocket ingress
   - HTTP frame ingress
3. **Runpod GPU worker** receives proxied `/v1/process_frame` and `/ws` traffic
4. **Processed JPEG output** returns to the mobile client

### Final single-machine path

Use the same compose stack with the `local-gpu` profile:

- `control-plane` container serves Nginx + FastAPI
- `gpu-worker` container runs the CUDA/PyTorch worker locally
- set `RUNPOD_BASE_URL=http://gpu-worker:8000`

That gives the same control-plane flow you test on DigitalOcean + Runpod, but collapsed onto one RTX 5060 server.

## Environment variables

Copy `.env.example` to `.env` and update:

| Variable | Required | Purpose |
| --- | --- | --- |
| `APP_ROLE` | yes | `control-plane` or `inference` |
| `ENABLE_NGINX` | yes | `true` for public ingress container, `false` for worker-only |
| `PUBLIC_BASE_URL` | yes | Public base URL used in generated session/client URLs |
| `SECRET_TOKEN` | yes | ****** for clients |
| `RUNPOD_SECRET_TOKEN` | yes | Token used between control plane and GPU worker |
| `RUNPOD_BASE_URL` | no | Empty for local CPU test, Runpod URL or `http://gpu-worker:8000` otherwise |
| `MODEL_DIR` | yes | Where models are mounted |
| `REQUEST_TIMEOUT_SECONDS` | yes | Timeout when proxying to Runpod |
| `SESSION_TTL_SECONDS` | yes | In-memory session lifetime |
| `MAX_IMAGE_BYTES` | yes | Upload/frame size guard |
| `CORS_ORIGINS` | yes | Comma-separated allowed origins |

## Flutter/mobile client contract

This repo does **not** include a full Flutter app yet. It now exposes a stable contract and a working browser client that Flutter can mirror directly.

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

`POST /v1/sessions` with `Authorization: ******`

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

- Header: `Authorization: ******`
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
cd /home/runner/work/face-swap-server/face-swap-server
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
cd /home/runner/work/face-swap-server/face-swap-server
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
scp -r /home/runner/work/face-swap-server/face-swap-server root@YOUR_DROPLET_IP:/opt/face-swap-server
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

Example:

```bash
cd /home/runner/work/face-swap-server/face-swap-server
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
