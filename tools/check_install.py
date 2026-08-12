#!/usr/bin/env python3
"""Small deployment preflight for the FaceSwap worker/control plane."""
import os
import sys
from pathlib import Path

role = os.getenv("APP_ROLE", "control-plane")
print(f"APP_ROLE={role}")
if role == "inference":
    model_dir = Path(os.getenv("MODEL_DIR", "/workspace/model/checkpoints"))
    model = model_dir / os.getenv("INSWAPPER_MODEL", "inswapper_128.onnx")
    print(f"model={model} exists={model.exists()}")
    try:
        import onnxruntime as ort
        providers = ort.get_available_providers()
        print("onnxruntime providers:", providers)
        if "CUDAExecutionProvider" not in providers:
            print("ERROR: CUDAExecutionProvider is unavailable", file=sys.stderr)
            sys.exit(2)
    except Exception as exc:
        print(f"ERROR: ONNX Runtime GPU check failed: {exc}", file=sys.stderr)
        sys.exit(2)
    if not model.exists():
        print("ERROR: face-swap model is missing", file=sys.stderr)
        sys.exit(3)
print("preflight OK")
