#!/usr/bin/env bash
# Production-oriented RunPod setup for an existing GPU Pod.
# Expected checkout: /workspace/face-swap-server
set -euo pipefail

APP_DIR="${APP_DIR:-/workspace/face-swap-server}"
MODEL_DIR="${MODEL_DIR:-/workspace/model/checkpoints}"
PORT="${PORT:-8000}"

if [ ! -d "$APP_DIR/backend" ]; then
  echo "ERROR: project not found at $APP_DIR" >&2
  exit 1
fi

apt-get update -qq
apt-get install -y --no-install-recommends python3-pip python3-venv build-essential curl libgl1 libglib2.0-0

python3 -m venv /workspace/.venv
source /workspace/.venv/bin/activate
pip install --upgrade pip setuptools wheel
pip install -r "$APP_DIR/backend/requirements-gpu.txt"

mkdir -p "$MODEL_DIR"
MODEL_FILE="$MODEL_DIR/${INSWAPPER_MODEL:-inswapper_128.onnx}"
if [ ! -f "$MODEL_FILE" ]; then
  echo "ERROR: face-swap model is missing: $MODEL_FILE" >&2
  echo "Place your licensed model at that path, then run this script again." >&2
  exit 2
fi

cat > "$APP_DIR/.env" <<ENV
APP_ROLE=inference
SECRET_TOKEN=${SECRET_TOKEN:?Set SECRET_TOKEN before running}
MODEL_DIR=$MODEL_DIR
INSWAPPER_MODEL=${INSWAPPER_MODEL:-inswapper_128.onnx}
FACE_ANALYSIS_NAME=${FACE_ANALYSIS_NAME:-buffalo_l}
FACE_DET_SIZE=${FACE_DET_SIZE:-256}
OUTPUT_JPEG_QUALITY=${OUTPUT_JPEG_QUALITY:-72}
OPENCV_THREADS=${OPENCV_THREADS:-1}
SESSION_TTL_SECONDS=${SESSION_TTL_SECONDS:-3600}
MAX_IMAGE_BYTES=${MAX_IMAGE_BYTES:-5242880}
LOG_LEVEL=${LOG_LEVEL:-INFO}
CORS_ORIGINS=*
ENV
chmod 600 "$APP_DIR/.env"

# Use a small watchdog loop because many RunPod base images don't run systemd.
cat > /workspace/start-faceswap.sh <<RUN
#!/usr/bin/env bash
set -euo pipefail
cd "$APP_DIR"
set -a
source "$APP_DIR/.env"
set +a
while true; do
  /workspace/.venv/bin/python -m uvicorn backend.app:app \\
    --host 0.0.0.0 --port "$PORT" --workers 1 \\
    --ws-ping-interval 15 --ws-ping-timeout 15 || true
  echo "faceswap worker exited; restarting in 2s" >&2
  sleep 2
done
RUN
chmod +x /workspace/start-faceswap.sh

pkill -f "uvicorn backend.app:app" 2>/dev/null || true
nohup /workspace/start-faceswap.sh >/workspace/faceswap.log 2>&1 &
sleep 3
curl -fsS "http://127.0.0.1:$PORT/health" || {
  echo "Worker did not become healthy. See /workspace/faceswap.log" >&2
  exit 3
}

echo "RunPod worker is running. Logs: /workspace/faceswap.log"
echo "Expose HTTP port $PORT in RunPod and use that HTTPS proxy URL as RUNPOD_BASE_URL on DigitalOcean."
