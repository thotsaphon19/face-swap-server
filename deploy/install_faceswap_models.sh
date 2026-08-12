#!/usr/bin/env bash
set -euo pipefail
ROOT="${ROOT:-/workspace/face-swap-server}"
MODEL_DIR="${MODEL_DIR:-/workspace/model/checkpoints}"
mkdir -p "$MODEL_DIR"
cd "$ROOT"
source /workspace/.venv/bin/activate
pip install insightface==0.7.3 onnxruntime-gpu==1.18.0

echo ""
echo "GPU dependencies installed."
echo "Place the licensed inswapper model at: $MODEL_DIR/inswapper_128.onnx"
echo "The face-analysis model package will be managed by InsightFace under MODEL_DIR."
echo "Do not use model files in commercial production unless you have the required model licenses."
