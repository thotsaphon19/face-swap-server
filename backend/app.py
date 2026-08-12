import asyncio
import io
import json
import logging
import os
import time
from datetime import UTC, datetime, timedelta
from typing import Any, Optional
from urllib.parse import urlencode, urljoin
from uuid import uuid4

import numpy as np
import requests
import websockets
from fastapi import FastAPI, File, Header, HTTPException, Request, UploadFile, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel, Field
from PIL import Image

try:
    import torch
    from torchvision import transforms
except Exception:
    torch = None
    transforms = None

LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO").upper()
APP_ROLE = os.getenv("APP_ROLE", "control-plane")
SECRET_TOKEN = os.getenv("SECRET_TOKEN", "testing123")
RUNPOD_BASE_URL = os.getenv("RUNPOD_BASE_URL", "").rstrip("/")
RUNPOD_SECRET_TOKEN = os.getenv("RUNPOD_SECRET_TOKEN", SECRET_TOKEN)
PUBLIC_BASE_URL = os.getenv("PUBLIC_BASE_URL", "").rstrip("/")
MODEL_DIR = os.getenv("MODEL_DIR", "/workspace/model/checkpoints")
REQUEST_TIMEOUT_SECONDS = float(os.getenv("REQUEST_TIMEOUT_SECONDS", "60"))
SESSION_TTL_SECONDS = int(os.getenv("SESSION_TTL_SECONDS", "3600"))
MAX_IMAGE_BYTES = int(os.getenv("MAX_IMAGE_BYTES", str(5 * 1024 * 1024)))
# Comma-separated list of allowed CORS origins; use * to allow all
CORS_ORIGINS = [origin.strip() for origin in os.getenv("CORS_ORIGINS", "*").split(",") if origin.strip()]
DEVICE = "cuda" if torch and torch.cuda.is_available() else "cpu"

logging.basicConfig(level=LOG_LEVEL)
logger = logging.getLogger("face-swap-server")

app = FastAPI(title="face-swap-server", version="0.2.0")

# Allow requests from Flutter app (and web PWA).
# When CORS_ORIGINS is "*", credentials must be disabled (CORS spec requirement).
_cors_wildcard = CORS_ORIGINS == ["*"] or not CORS_ORIGINS
app.add_middleware(
    CORSMiddleware,
    allow_origins=CORS_ORIGINS or ["*"],
    allow_credentials=not _cors_wildcard,
    allow_methods=["*"],
    allow_headers=["*"],
)

_model = None
_model_lock = asyncio.Lock()
_session_lock = asyncio.Lock()
_sessions: dict[str, dict[str, Any]] = {}


class SessionCreateRequest(BaseModel):
    client_name: Optional[str] = None
    transport: str = "ws"
    resolution: Optional[str] = None
    fps: Optional[int] = None
    metadata: dict[str, Any] = Field(default_factory=dict)


class SessionActionResponse(BaseModel):
    session_id: str
    status: str
    created_at: str
    updated_at: str
    expires_at: str
    transport: str
    client_name: Optional[str] = None
    resolution: Optional[str] = None
    fps: Optional[int] = None
    ws_url: str
    process_frame_url: str
    stop_url: str
    metadata: dict[str, Any] = Field(default_factory=dict)


def utc_now() -> datetime:
    return datetime.now(UTC)


def isoformat(dt: datetime) -> str:
    return dt.isoformat().replace("+00:00", "Z")


def normalize_base_url(request: Request | None = None) -> str:
    if PUBLIC_BASE_URL:
        return PUBLIC_BASE_URL
    if request is None:
        return "http://localhost"
    return str(request.base_url).rstrip("/")


def to_public_ws_url(base_url: str, path: str, params: dict[str, str]) -> str:
    query = f"?{urlencode(params)}" if params else ""
    if base_url.startswith("https://"):
        scheme = "wss://"
        host = base_url[len("https://") :]
    elif base_url.startswith("http://"):
        scheme = "ws://"
        host = base_url[len("http://") :]
    elif base_url.startswith("wss://") or base_url.startswith("ws://"):
        return f"{base_url.rstrip('/')}{path}{query}"
    else:
        scheme = "ws://"
        host = base_url
    return f"{scheme}{host.rstrip('/')}{path}{query}"


def runpod_ws_url(session_id: Optional[str]) -> str:
    base_url = RUNPOD_BASE_URL
    if base_url.startswith("https://"):
        base_url = "wss://" + base_url[len("https://") :]
    elif base_url.startswith("http://"):
        base_url = "ws://" + base_url[len("http://") :]
    params = {"token": RUNPOD_SECRET_TOKEN}
    if session_id:
        params["session_id"] = session_id
    return f"{base_url}/ws?{urlencode(params)}"


def should_proxy_to_runpod() -> bool:
    return APP_ROLE == "control-plane" and bool(RUNPOD_BASE_URL)


def ensure_max_size(content: bytes):
    if len(content) > MAX_IMAGE_BYTES:
        raise HTTPException(status_code=413, detail=f"Image too large. Limit is {MAX_IMAGE_BYTES} bytes")


def load_model():
    global _model
    if _model is not None:
        return _model

    class DummyModel:
        def __call__(self, img_tensor):
            return img_tensor

    _model = DummyModel()
    logger.info("Loaded dummy model. Replace load_model() with the production face-swap model.")
    return _model


def pil_to_tensor(img: Image.Image):
    if transforms:
        tf = transforms.Compose([transforms.ToTensor()])
        return tf(img).unsqueeze(0).to(DEVICE)
    arr = np.array(img).astype(np.float32) / 255.0
    arr = np.transpose(arr, (2, 0, 1))
    if torch:
        return torch.from_numpy(arr).unsqueeze(0).to(DEVICE)
    return None


def tensor_to_pil(tensor):
    if torch and isinstance(tensor, torch.Tensor):
        arr = tensor.squeeze(0).cpu().clamp(0, 1).numpy()
        arr = np.transpose(arr, (1, 2, 0)) * 255
        arr = arr.astype("uint8")
        return Image.fromarray(arr)
    return None


async def process_image_locally(content: bytes) -> tuple[bytes, int]:
    ensure_max_size(content)
    started = time.perf_counter()
    try:
        img = Image.open(io.BytesIO(content)).convert("RGB")
    except Exception as exc:
        logger.exception("Failed to open image")
        raise HTTPException(status_code=400, detail="Invalid image") from exc

    async with _model_lock:
        model = load_model()

    if torch and transforms:
        tensor = pil_to_tensor(img)
        try:
            out_tensor = model(tensor)
            out_img = tensor_to_pil(out_tensor)
        except Exception:
            logger.exception("Model inference failed, falling back to original image")
            out_img = img
    else:
        out_img = img

    buf = io.BytesIO()
    out_img.save(buf, format="JPEG")
    return buf.getvalue(), int((time.perf_counter() - started) * 1000)


async def proxy_process_frame(content: bytes, filename: str, content_type: str, session_id: Optional[str]) -> tuple[bytes, str, int]:
    ensure_max_size(content)
    headers = {"Authorization": f"******"}
    if session_id:
        headers["X-Session-Id"] = session_id
    files = {"file": (filename or "frame.jpg", content, content_type or "image/jpeg")}
    started = time.perf_counter()
    try:
        response = await asyncio.to_thread(
            requests.post,
            f"{RUNPOD_BASE_URL}/v1/process_frame",
            files=files,
            headers=headers,
            timeout=REQUEST_TIMEOUT_SECONDS,
        )
    except requests.RequestException as exc:
        logger.exception("Runpod request failed")
        raise HTTPException(status_code=502, detail="Failed to reach GPU inference service") from exc

    elapsed_ms = int((time.perf_counter() - started) * 1000)
    if response.status_code >= 400:
        detail = response.text
        try:
            detail = response.json().get("detail", detail)
        except ValueError:
            pass
        status_code = response.status_code if 400 <= response.status_code < 500 else 502
        raise HTTPException(status_code=status_code, detail=f"GPU inference service error: {detail}")

    return response.content, response.headers.get("content-type", "image/jpeg"), elapsed_ms


def session_response(record: dict[str, Any], request: Request) -> SessionActionResponse:
    base_url = normalize_base_url(request)
    return SessionActionResponse(
        session_id=record["session_id"],
        status=record["status"],
        created_at=record["created_at"],
        updated_at=record["updated_at"],
        expires_at=record["expires_at"],
        transport=record["transport"],
        client_name=record.get("client_name"),
        resolution=record.get("resolution"),
        fps=record.get("fps"),
        ws_url=to_public_ws_url(base_url, "/ws", {"session_id": record["session_id"]}),
        process_frame_url=urljoin(f"{base_url}/", "v1/process_frame"),
        stop_url=urljoin(f"{base_url}/", f"v1/sessions/{record['session_id']}/stop"),
        metadata=record.get("metadata", {}),
    )


async def cleanup_expired_sessions():
    now = utc_now()
    expired_ids = [session_id for session_id, record in _sessions.items() if datetime.fromisoformat(record["expires_at"].replace("Z", "+00:00")) <= now]
    for session_id in expired_ids:
        _sessions.pop(session_id, None)


async def create_session(payload: SessionCreateRequest) -> dict[str, Any]:
    async with _session_lock:
        await cleanup_expired_sessions()
        now = utc_now()
        session_id = uuid4().hex
        record = {
            "session_id": session_id,
            "status": "created",
            "created_at": isoformat(now),
            "updated_at": isoformat(now),
            "expires_at": isoformat(now + timedelta(seconds=SESSION_TTL_SECONDS)),
            "transport": payload.transport,
            "client_name": payload.client_name,
            "resolution": payload.resolution,
            "fps": payload.fps,
            "metadata": payload.metadata,
        }
        _sessions[session_id] = record
        return record


async def get_session_or_404(session_id: str) -> dict[str, Any]:
    async with _session_lock:
        await cleanup_expired_sessions()
        record = _sessions.get(session_id)
        if not record:
            raise HTTPException(status_code=404, detail="Session not found")
        return record


async def touch_session(session_id: Optional[str], status: Optional[str] = None):
    if not session_id:
        return
    async with _session_lock:
        await cleanup_expired_sessions()
        record = _sessions.get(session_id)
        if not record:
            raise HTTPException(status_code=404, detail="Session not found")
        now = utc_now()
        record["updated_at"] = isoformat(now)
        record["expires_at"] = isoformat(now + timedelta(seconds=SESSION_TTL_SECONDS))
        if status:
            record["status"] = status


def extract_session_id(request: Request, explicit_session_id: Optional[str]) -> Optional[str]:
    return explicit_session_id or request.headers.get("X-Session-Id")


def check_auth_header(auth_header: Optional[str]):
    if not SECRET_TOKEN:
        return
    if not auth_header:
        raise HTTPException(status_code=401, detail="Missing Authorization")
    if not auth_header.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Invalid Authorization header")
    token = auth_header.split(" ", 1)[1].strip()
    if token != SECRET_TOKEN:
        raise HTTPException(status_code=401, detail="Invalid token")


@app.get("/health")
async def health():
    await cleanup_expired_sessions()
    return {
        "status": "ok",
        "role": APP_ROLE,
        "device": DEVICE,
        "runpod_proxy_enabled": should_proxy_to_runpod(),
        "model_dir": MODEL_DIR,
        "active_sessions": len(_sessions),
    }


@app.get("/v1/client-config")
async def client_config(request: Request):
    base_url = normalize_base_url(request)
    return {
        "role": APP_ROLE,
        "http_process_url": urljoin(f"{base_url}/", "v1/process_frame"),
        "session_create_url": urljoin(f"{base_url}/", "v1/sessions"),
        "ws_url": to_public_ws_url(base_url, "/ws", {}),
        "requires_bearer_token": bool(SECRET_TOKEN),
        "binary_frame_format": "jpeg-bytes",
        "max_image_bytes": MAX_IMAGE_BYTES,
        "session_ttl_seconds": SESSION_TTL_SECONDS,
    }


@app.post("/v1/sessions", response_model=SessionActionResponse)
async def create_session_endpoint(payload: SessionCreateRequest, request: Request, authorization: str | None = Header(None)):
    check_auth_header(authorization)
    record = await create_session(payload)
    return session_response(record, request)


@app.get("/v1/sessions/{session_id}", response_model=SessionActionResponse)
async def get_session_endpoint(session_id: str, request: Request, authorization: str | None = Header(None)):
    check_auth_header(authorization)
    record = await get_session_or_404(session_id)
    return session_response(record, request)


@app.post("/v1/sessions/{session_id}/start", response_model=SessionActionResponse)
async def start_session_endpoint(session_id: str, request: Request, authorization: str | None = Header(None)):
    check_auth_header(authorization)
    await touch_session(session_id, "active")
    record = await get_session_or_404(session_id)
    return session_response(record, request)


@app.post("/v1/sessions/{session_id}/stop", response_model=SessionActionResponse)
async def stop_session_endpoint(session_id: str, request: Request, authorization: str | None = Header(None)):
    check_auth_header(authorization)
    await touch_session(session_id, "stopped")
    record = await get_session_or_404(session_id)
    return session_response(record, request)


@app.post("/v1/process_frame")
async def process_frame(
    request: Request,
    file: UploadFile = File(...),
    authorization: str | None = Header(None),
    session_id: str | None = None,
):
    check_auth_header(authorization)
    resolved_session_id = extract_session_id(request, session_id)
    if resolved_session_id:
        await touch_session(resolved_session_id, "active")

    content = await file.read()
    if should_proxy_to_runpod():
        body, media_type, elapsed_ms = await proxy_process_frame(content, file.filename or "frame.jpg", file.content_type or "image/jpeg", resolved_session_id)
    else:
        body, elapsed_ms = await process_image_locally(content)
        media_type = "image/jpeg"

    return Response(content=body, media_type=media_type, headers={"X-Process-Time-Ms": str(elapsed_ms)})


async def relay_websocket_to_runpod(ws: WebSocket, session_id: Optional[str]):
    await ws.accept()
    remote_url = runpod_ws_url(session_id)
    logger.info("Relaying websocket session to remote GPU service")
    try:
        async with websockets.connect(remote_url, open_timeout=REQUEST_TIMEOUT_SECONDS, max_size=MAX_IMAGE_BYTES * 2) as upstream:
            async def client_to_upstream():
                while True:
                    message = await ws.receive()
                    if message["type"] == "websocket.disconnect":
                        break
                    if message.get("bytes") is not None:
                        payload = message["bytes"]
                        ensure_max_size(payload)
                        await upstream.send(payload)
                    elif message.get("text") is not None:
                        await upstream.send(message["text"])

            async def upstream_to_client():
                while True:
                    payload = await upstream.recv()
                    if isinstance(payload, bytes):
                        await ws.send_bytes(payload)
                    else:
                        await ws.send_text(payload)

            done, pending = await asyncio.wait(
                [asyncio.create_task(client_to_upstream()), asyncio.create_task(upstream_to_client())],
                return_when=asyncio.FIRST_EXCEPTION,
            )
            for task in pending:
                task.cancel()
            for task in done:
                exc = task.exception()
                if exc:
                    raise exc
    except WebSocketDisconnect:
        logger.info("Client websocket disconnected during relay")
    except Exception:
        logger.exception("Websocket relay error")
        await ws.close(code=1011)


@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket):
    params = dict(ws.query_params)
    token = params.get("token") or None
    session_id = params.get("session_id") or None

    if SECRET_TOKEN and token != SECRET_TOKEN:
        await ws.close(code=1008)
        return

    if session_id:
        try:
            await touch_session(session_id, "active")
        except HTTPException:
            await ws.close(code=1008)
            return

    if should_proxy_to_runpod():
        await relay_websocket_to_runpod(ws, session_id)
        return

    await ws.accept()
    try:
        while True:
            data = await ws.receive_bytes()
            if session_id:
                await touch_session(session_id, "active")
            try:
                out_bytes, _ = await process_image_locally(data)
            except HTTPException as exc:
                await ws.send_text(json.dumps({"error": exc.detail}))
                continue
            await ws.send_bytes(out_bytes)
    except WebSocketDisconnect:
        logger.info("WebSocket disconnected")
    except Exception:
        logger.exception("WebSocket error")
        await ws.close()


@app.exception_handler(HTTPException)
async def http_exception_handler(_: Request, exc: HTTPException):
    return JSONResponse(status_code=exc.status_code, content={"detail": exc.detail})