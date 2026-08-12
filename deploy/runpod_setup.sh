#!/usr/bin/env bash
# =============================================================================
# Runpod GPU Setup Script
# Run this inside a Runpod GPU pod (RTX 3090 / A5000 / A100 recommended)
# after SSH-ing in or using the Runpod terminal.
#
# Usage:
#   chmod +x deploy/runpod_setup.sh
#   bash deploy/runpod_setup.sh
# =============================================================================
set -euo pipefail

echo "[runpod] Installing system deps..."
apt-get update -qq && apt-get install -y --no-install-recommends \
    python3-pip python3-venv git curl wget nginx

echo "[runpod] Creating Python venv..."
python3 -m venv /workspace/.venv
source /workspace/.venv/bin/activate

echo "[runpod] Installing PyTorch (CUDA 12.1)..."
pip install --upgrade pip
pip install --index-url https://download.pytorch.org/whl/cu121 \
    torch torchvision torchaudio

echo "[runpod] Installing backend requirements..."
pip install -r /workspace/face-swap-server/backend/requirements.txt

echo "[runpod] Installing uvicorn..."
pip install "uvicorn[standard]>=0.22"

# ── Model directory ─────────────────────────────────────────────────────────
MODEL_DIR="${MODEL_DIR:-/workspace/model/checkpoints}"
mkdir -p "$MODEL_DIR"
echo "[runpod] Model dir: $MODEL_DIR"
echo "         Place your face-swap model checkpoint files here."

# ── Environment ─────────────────────────────────────────────────────────────
cat > /workspace/face-swap-server/.env <<EOF
SECRET_TOKEN=${SECRET_TOKEN:-changeme_runpod}
WORKER_PORT=8000
MODEL_DIR=${MODEL_DIR}
LOG_LEVEL=INFO
CORS_ORIGINS=*
EOF
echo "[runpod] Written .env"

# ── Start uvicorn (background) ───────────────────────────────────────────────
echo "[runpod] Starting uvicorn on 0.0.0.0:8000 ..."
cd /workspace/face-swap-server
nohup /workspace/.venv/bin/uvicorn backend.app:app \
    --host 0.0.0.0 --port 8000 \
    --workers 1 \
    --log-level info \
    > /workspace/uvicorn.log 2>&1 &

echo "[runpod] Uvicorn PID: $!"
echo "[runpod] Logs: /workspace/uvicorn.log"
echo ""
echo "=== Runpod setup complete ==="
echo "Test: curl http://localhost:8000/health"
echo ""
echo "Expose port 8000 via Runpod's TCP proxy."
echo "Flutter app should connect to:  ws://<RUNPOD_PUBLIC_HOST>:<PROXY_PORT>/ws?token=<TOKEN>"
