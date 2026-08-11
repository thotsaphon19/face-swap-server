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

GitHub Actions image publishing
- The `docker-image.yml` workflow publishes `latest` to Docker Hub.
- Configure these repository secrets before running the workflow:
  - `DOCKERHUB_USERNAME` : your Docker Hub username (namespace)
  - `DOCKERHUB_TOKEN` : Docker Hub access token with push permission