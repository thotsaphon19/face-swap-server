# FaceSwap Camera — Production deployment

This build is optimized for **low-latency Android camera → GPU face swap → Android preview**.
It intentionally prefers a fresh frame over a high frame count: there is at most one inference frame in flight, so slow GPU/network conditions reduce FPS instead of accumulating old frames. That is what keeps mouth movement closer to the current camera image.

## Production topology

Android Flutter app → `wss://api.example.com/ws` → DigitalOcean control plane → RunPod GPU worker → processed JPEG → Android app.

For lowest latency, place the DigitalOcean gateway and GPU worker geographically close to the users. Avoid RunPod Serverless cold starts for a live camera session; use a running GPU Pod / dedicated worker.

## 1. GPU worker (RunPod)

Recommended starting point: NVIDIA RTX 4090 / L40S class GPU, persistent running Pod, HTTP port 8000 exposed by RunPod.

Checkout this repository at `/workspace/face-swap-server`, place your licensed face-swap model at:

```bash
/workspace/model/checkpoints/inswapper_128.onnx
```

Then:

```bash
cd /workspace/face-swap-server
export SECRET_TOKEN='LONG_INTERNAL_GPU_SECRET'
bash deploy/runpod_setup.sh
```

Verify:

```bash
curl http://127.0.0.1:8000/health
nvidia-smi
cat /workspace/faceswap.log
```

Use the HTTPS proxy URL RunPod gives for port 8000 as `RUNPOD_BASE_URL` below.

## 2. Control plane (DigitalOcean)

Create a nearby Ubuntu 22.04/24.04 Droplet, point `api.example.com` to its public IP, then run as root:

```bash
export REPO_URL='https://github.com/YOUR_ACCOUNT/YOUR_REPO.git'
export DOMAIN='api.example.com'
export SECRET_TOKEN='LONG_PUBLIC_APP_TOKEN'
export RUNPOD_BASE_URL='https://YOUR-RUNPOD-PROXY-URL'
export RUNPOD_SECRET_TOKEN='LONG_INTERNAL_GPU_SECRET'
bash deploy/digitalocean_setup.sh
```

Verify:

```bash
curl https://api.example.com/health
systemctl status faceswap
journalctl -u faceswap -f
```

## 3. Android app

Use `flutter_app/`.

```bash
cd flutter_app
flutter pub get
flutter build apk --release
```

Install for direct testing:

```bash
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

Open the app and enter:

- Server URL: `https://api.example.com`
- Auth token: same value as DigitalOcean `SECRET_TOKEN`

Select a clear source face, wait for `SRC READY`, then tap **Start Stream**.

## Low-latency defaults

- Camera: 480p (`ResolutionPreset.medium`)
- Requested FPS: 8 initially; raise to 10–12 only after observing stable RTT
- Client JPEG quality: adaptive 70 → 62 → 55 as RTT rises
- Server face detector: 256×256
- Server output JPEG quality: 72
- One frame in flight: yes (no stale-frame queue)
- WebSocket application heartbeat: 12 s
- WebSocket watchdog: 35 s
- Auto reconnect: yes
- Source face restored after reconnect: yes

The actual achievable FPS/latency depends on phone CPU, uplink, internet route, GPU type/load and physical distance to the GPU. A server-side face swap cannot guarantee zero latency; the goal of this build is to prevent latency from continually growing.

## Stability checklist

Before using it for a long session:

```bash
# DigitalOcean
journalctl -u faceswap -f

# RunPod
watch -n 1 nvidia-smi
 tail -f /workspace/faceswap.log
```

Run the camera for at least 20–30 minutes. Desired behavior is stable memory use, no growing frame delay, automatic recovery after toggling Wi‑Fi/mobile data, and source-face restoration after reconnect.

## Important limitation: LINE / Instagram / Facebook camera selection

This repository provides a real face-swap camera **inside the Flutter app**. A normal Android/iOS application cannot generally register its rendered output as a new system camera that arbitrary third-party apps such as LINE, Instagram or Facebook must accept. That is an OS/app integration limitation, not a WebSocket or face-swap issue. Do not assume installing this APK will make “FaceSwap Cam” appear as a selectable camera inside those apps.

## GPU preflight

After installing the RunPod environment:

```bash
cd /workspace/face-swap-server
set -a; source .env; set +a
/workspace/.venv/bin/python tools/check_install.py
```

It must report `CUDAExecutionProvider` before realtime testing.
