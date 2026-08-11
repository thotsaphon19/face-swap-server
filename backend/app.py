from fastapi import FastAPI, File, UploadFile, HTTPException, Header, WebSocket, WebSocketDisconnect
from fastapi.responses import StreamingResponse, HTMLResponse
import os, io, logging, asyncio, json
from PIL import Image
import numpy as np
from typing import Optional

# optional torch import (lazy)
try:
    import torch
    from torchvision import transforms
except Exception:
    torch = None
    transforms = None

LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO")
SECRET_TOKEN = os.getenv("SECRET_TOKEN", "testing123")
MODEL_DIR = os.getenv("MODEL_DIR", "/workspace/model/checkpoints")
DEVICE = "cuda" if torch and torch.cuda.is_available() else "cpu"

logging.basicConfig(level=LOG_LEVEL)
logger = logging.getLogger("face-swap-server")

app = FastAPI(title="face-swap-server", version="0.1")

_model = None
_model_lock = asyncio.Lock()

def load_model():
    global _model
    if _model is not None:
        return _model
    # Placeholder: Replace with real model load
    class DummyModel:
        def __call__(self, img_tensor):
            # identity
            return img_tensor
    _model = DummyModel()
    logger.info("Loaded dummy model (replace with real model load).")
    return _model

def pil_to_tensor(img: Image.Image):
    if transforms:
        tf = transforms.Compose([transforms.ToTensor()])
        return tf(img).unsqueeze(0).to(DEVICE)
    else:
        arr = np.array(img).astype(np.float32) / 255.0
        arr = np.transpose(arr, (2,0,1))
        if torch:
            return torch.from_numpy(arr).unsqueeze(0).to(DEVICE)
        return None

def tensor_to_pil(tensor):
    if torch and isinstance(tensor, torch.Tensor):
        arr = tensor.squeeze(0).cpu().clamp(0,1).numpy()
        arr = np.transpose(arr, (1,2,0)) * 255
        arr = arr.astype("uint8")
        return Image.fromarray(arr)
    else:
        return None

@app.get("/health")
async def health():
    return {"status": "ok", "device": DEVICE}

@app.get("/connect")
async def connect_info():
    """Flutter client calls this to confirm backend is reachable and learn session details."""
    return {
        "status": "ready",
        "device": DEVICE,
        "ws_path": "/ws",
        "process_path": "/v1/process_frame",
        "auth_required": bool(SECRET_TOKEN),
    }

@app.get("/session")
async def session_status():
    """Returns lightweight session state (model loaded, device info)."""
    return {
        "model_loaded": _model is not None,
        "device": DEVICE,
    }

def check_auth_header(auth_header: Optional[str]):
    if SECRET_TOKEN:
        if not auth_header:
            raise HTTPException(status_code=401, detail="Missing Authorization")
        if not auth_header.startswith("Bearer "):
            raise HTTPException(status_code=401, detail="Invalid Authorization header")
        token = auth_header.split(" ",1)[1].strip()
        if token != SECRET_TOKEN:
            raise HTTPException(status_code=401, detail="Invalid token")

@app.post("/v1/process_frame")
async def process_frame(file: UploadFile = File(...), authorization: str | None = Header(None)):
    try:
        check_auth_header(authorization)
    except HTTPException as e:
        raise e

    content = await file.read()
    try:
        img = Image.open(io.BytesIO(content)).convert("RGB")
    except Exception:
        logger.exception("Failed to open image")
        raise HTTPException(status_code=400, detail="Invalid image")

    # load model lazily with lock to avoid concurrent loads
    async with _model_lock:
        model = load_model()

    if torch and transforms:
        tensor = pil_to_tensor(img)
        try:
            out_tensor = model(tensor)
            out_img = tensor_to_pil(out_tensor)
        except Exception:
            logger.exception("Model inference failed, falling back to original")
            out_img = img
    else:
        out_img = img

    buf = io.BytesIO()
    out_img.save(buf, format="JPEG")
    buf.seek(0)
    return StreamingResponse(buf, media_type="image/jpeg")

# Simple WebSocket binary frame handler:
# Accepts binary JPEG frames and returns processed JPEG bytes
@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket):
    # optional: token in query params
    params = dict(ws.query_params)
    token = params.get("token") or None
    # Validate token
    if SECRET_TOKEN and token != SECRET_TOKEN:
        await ws.close(code=1008)
        return
    await ws.accept()
    try:
        while True:
            data = await ws.receive_bytes()
            # process bytes similar to POST endpoint
            try:
                img = Image.open(io.BytesIO(data)).convert("RGB")
            except Exception:
                # send a small JSON error as text
                await ws.send_text(json.dumps({"error":"invalid_image"}))
                continue

            # ensure model loaded
            async with _model_lock:
                model = load_model()

            if torch and transforms:
                tensor = pil_to_tensor(img)
                try:
                    out_tensor = model(tensor)
                    out_img = tensor_to_pil(out_tensor)
                except Exception:
                    logger.exception("Model inference failed, fallback")
                    out_img = img
            else:
                out_img = img

            buf = io.BytesIO()
            out_img.save(buf, format="JPEG")
            buf.seek(0)
            await ws.send_bytes(buf.read())
    except WebSocketDisconnect:
        logger.info("WebSocket disconnected")
    except Exception:
        logger.exception("WebSocket error")
        await ws.close()