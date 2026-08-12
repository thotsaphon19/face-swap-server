import asyncio
import io
import json
import logging
import os
import socket
import time
from datetime import UTC, datetime, timedelta
from typing import Any, Optional
from urllib.parse import urlencode, urljoin
from uuid import uuid4

import numpy as np
import requests
import websockets
from backend.faceswap_engine import FaceSwapEngine
from fastapi import FastAPI, File, Header, HTTPException, Request, UploadFile, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, JSONResponse, Response
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

app = FastAPI(title="face-swap-server", version="0.6.0")

# Allow requests from Flutter apps (both flutter_client/ and mobile/) and the web PWA.
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
_faceswap_engine = FaceSwapEngine()
_session_lock = asyncio.Lock()
# Single shared session store used by BOTH API contracts:
#   - flutter_client/ : /v1/sessions (plural, full lifecycle)
#   - mobile/          : /v1/session  (singular, simplified)
# A session created through either contract is visible through the other.
_sessions: dict[str, dict[str, Any]] = {}
# Desktop viewers (OBS/browser receiver) subscribed by logical session.
# Each viewer receives only newly processed frames; a slow viewer is removed
# instead of back-pressuring the mobile/GPU realtime path.
_viewers: dict[str, set[WebSocket]] = {}
_viewers_lock = asyncio.Lock()



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



async def broadcast_processed_frame(session_id: Optional[str], payload: bytes) -> None:
    """Fan out one processed JPEG to desktop viewers without slowing inference."""
    if not session_id:
        return
    async with _viewers_lock:
        targets = list(_viewers.get(session_id, set()))
    if not targets:
        return

    async def _send(viewer: WebSocket):
        try:
            # A desktop receiver that cannot accept a frame quickly is stale.
            await asyncio.wait_for(viewer.send_bytes(payload), timeout=0.12)
            return None
        except Exception:
            return viewer

    stale = [v for v in await asyncio.gather(*(_send(v) for v in targets)) if v is not None]
    if stale:
        async with _viewers_lock:
            bucket = _viewers.get(session_id)
            if bucket:
                for viewer in stale:
                    bucket.discard(viewer)
                if not bucket:
                    _viewers.pop(session_id, None)


VIEWER_HTML = r"""<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>FaceSwap Camera Receiver</title>
<style>html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#000}#frame{width:100vw;height:100vh;display:block;background:#000}#status{position:fixed;left:12px;top:12px;padding:6px 10px;border-radius:16px;background:#000a;color:white;font:13px system-ui;z-index:2}</style>
</head><body><canvas id="frame"></canvas><div id="status">CONNECTING</div><script>
const q=new URLSearchParams(location.search); const sid=q.get('session_id')||''; const token=q.get('token')||'';
const st=document.getElementById('status'), canvas=document.getElementById('frame'), ctx=canvas.getContext('2d',{alpha:false});
let ws, retry=500, latest=null, decoding=false, frames=0, lastFps=performance.now();
function fit(){canvas.width=Math.max(2,Math.floor(innerWidth*devicePixelRatio));canvas.height=Math.max(2,Math.floor(innerHeight*devicePixelRatio));} addEventListener('resize',fit); fit();
async function pump(){
 if(decoding || !latest) return; decoding=true; const blob=latest; latest=null;
 try { const bmp=await createImageBitmap(blob); const cw=canvas.width,ch=canvas.height, r=Math.max(cw/bmp.width,ch/bmp.height); const w=bmp.width*r,h=bmp.height*r; ctx.drawImage(bmp,(cw-w)/2,(ch-h)/2,w,h); bmp.close(); frames++; }
 catch(e){}
 decoding=false; if(latest) pump();
}
function connect(){
 const proto=location.protocol==='https:'?'wss:':'ws:';
 ws=new WebSocket(`${proto}//${location.host}/ws/viewer?session_id=${encodeURIComponent(sid)}&token=${encodeURIComponent(token)}`); ws.binaryType='blob';
 ws.onopen=()=>{st.textContent='LIVE';retry=500};
 ws.onmessage=(e)=>{if(typeof e.data==='string')return; latest=e.data; pump()};
 ws.onclose=()=>{st.textContent='RECONNECTING';setTimeout(connect,retry);retry=Math.min(retry*1.5,4000)};
 ws.onerror=()=>ws.close();
}
setInterval(()=>{if(ws&&ws.readyState===1)ws.send(JSON.stringify({type:'ping'})); const now=performance.now(); const fps=frames*1000/Math.max(1,now-lastFps); frames=0;lastFps=now;if(ws&&ws.readyState===1)st.textContent=`LIVE ${fps.toFixed(0)} FPS`;},2000);
if(!sid){st.textContent='MISSING session_id'} else connect();
</script></body></html>"""

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
    """Backward-compatible model health hook. Real inference uses FaceSwapEngine."""
    return _faceswap_engine


async def process_image_locally(content: bytes, session_id: Optional[str] = None) -> tuple[bytes, int]:
    ensure_max_size(content)
    started = time.perf_counter()
    if not session_id:
        raise HTTPException(status_code=400, detail="session_id is required for face-swap inference")
    try:
        async with _model_lock:
            out_bytes = await asyncio.to_thread(_faceswap_engine.process, session_id, content)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    return out_bytes, int((time.perf_counter() - started) * 1000)


async def proxy_process_frame(content: bytes, filename: str, content_type: str, session_id: Optional[str]) -> tuple[bytes, str, int]:
    ensure_max_size(content)
    headers = {"Authorization": f"Bearer {RUNPOD_SECRET_TOKEN}"}
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
        # Source faces are cached on the inference worker for the life of a
        # logical session, not the life of one WebSocket connection.
        _faceswap_engine.clear_source(session_id)


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
        "faceswap_engine": _faceswap_engine.status(),
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
    _faceswap_engine.clear_source(session_id)
    record = await get_session_or_404(session_id)
    return session_response(record, request)


# ---------------------------------------------------------------------------
# Simplified singular-session endpoints used by the `mobile/` (iVCam-style)
# Flutter client. These share the SAME _sessions store as the /v1/sessions
# endpoints above via create_session()/get_session_or_404(), so a session
# created through either contract is visible through the other.
# ---------------------------------------------------------------------------


@app.get("/v1/gpu/status")
async def gpu_status(authorization: str | None = Header(None)):
    check_auth_header(authorization)
    return _faceswap_engine.status()


@app.get("/v1/info")
async def server_info():
    """Public (no-auth) server info used by the `mobile/` client's home-screen
    health-check polling, so it can confirm connectivity and display basic
    server details before the user connects."""
    try:
        hostname = socket.gethostname()
        host_ip = socket.gethostbyname(hostname)
    except Exception:
        hostname = "unknown"
        host_ip = "unknown"
    return {
        "server": "face-swap-server",
        "version": app.version,
        "device": DEVICE,
        "hostname": hostname,
        "ip": host_ip,
    }


@app.post("/v1/session")
async def create_session_singular(authorization: str | None = Header(None)):
    """Simplified session-create endpoint for the `mobile/` client. Internally
    delegates to the same session store as POST /v1/sessions."""
    check_auth_header(authorization)
    record = await create_session(SessionCreateRequest(client_name="mobile"))
    return {"session_id": record["session_id"]}


@app.get("/v1/session/{session_id}")
async def get_session_singular(session_id: str, authorization: str | None = Header(None)):
    check_auth_header(authorization)
    record = await get_session_or_404(session_id)
    return {
        "session_id": record["session_id"],
        "status": record["status"],
        "created_at": record["created_at"],
        "updated_at": record["updated_at"],
    }


@app.delete("/v1/session/{session_id}")
async def delete_session_singular(session_id: str, authorization: str | None = Header(None)):
    check_auth_header(authorization)
    async with _session_lock:
        if session_id not in _sessions:
            raise HTTPException(status_code=404, detail="Session not found")
        del _sessions[session_id]
    logger.info("Session deleted via /v1/session/%s (mobile client)", session_id)
    return {"deleted": True}


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
        body, elapsed_ms = await process_image_locally(content, resolved_session_id)
        media_type = "image/jpeg"

    return Response(content=body, media_type=media_type, headers={"X-Process-Time-Ms": str(elapsed_ms)})


async def relay_websocket_to_runpod(ws: WebSocket, session_id: Optional[str]):
    await ws.accept()
    remote_url = runpod_ws_url(session_id)
    logger.info("Relaying websocket session to remote GPU service")
    try:
        async with websockets.connect(
            remote_url,
            open_timeout=REQUEST_TIMEOUT_SECONDS,
            max_size=MAX_IMAGE_BYTES * 2,
            max_queue=1,
            ping_interval=15,
            ping_timeout=15,
            compression=None,
        ) as upstream:
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
                        await broadcast_processed_frame(session_id, payload)
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



@app.get("/viewer", response_class=HTMLResponse)
async def desktop_viewer_page():
    return HTMLResponse(VIEWER_HTML, headers={"Cache-Control": "no-store"})


@app.websocket("/ws/viewer")
async def desktop_viewer_ws(ws: WebSocket):
    params = dict(ws.query_params)
    token = params.get("token") or None
    session_id = params.get("session_id") or None
    if SECRET_TOKEN and token != SECRET_TOKEN:
        await ws.close(code=1008)
        return
    if not session_id:
        await ws.close(code=1008)
        return
    try:
        await touch_session(session_id, "active")
    except HTTPException:
        await ws.close(code=1008)
        return

    await ws.accept()
    async with _viewers_lock:
        _viewers.setdefault(session_id, set()).add(ws)
    logger.info("Desktop viewer connected for session %s", session_id)
    try:
        # Keep the socket alive. Frames are pushed by broadcast_processed_frame().
        while True:
            message = await ws.receive()
            if message.get("type") == "websocket.disconnect":
                break
            if message.get("text"):
                try:
                    data = json.loads(message["text"])
                    if data.get("type") == "ping":
                        await ws.send_text(json.dumps({"type":"pong"}))
                except Exception:
                    pass
    except WebSocketDisconnect:
        pass
    finally:
        async with _viewers_lock:
            bucket = _viewers.get(session_id)
            if bucket:
                bucket.discard(ws)
                if not bucket:
                    _viewers.pop(session_id, None)
        logger.info("Desktop viewer disconnected for session %s", session_id)

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
        effective_session = session_id or f"ws-{id(ws)}"
        while True:
            message = await ws.receive()
            if message.get("type") == "websocket.disconnect":
                break
            if session_id:
                await touch_session(session_id, "active")

            text = message.get("text")
            if text is not None:
                try:
                    control = json.loads(text)
                except json.JSONDecodeError:
                    await ws.send_text(json.dumps({"type": "error", "error": "Invalid JSON control message"}))
                    continue

                if control.get("type") == "source_face":
                    import base64
                    try:
                        source_bytes = base64.b64decode(control["image_base64"], validate=True)
                        await asyncio.to_thread(_faceswap_engine.set_source, effective_session, source_bytes)
                        await ws.send_text(json.dumps({"type": "source_face_ready"}))
                    except Exception as exc:
                        await ws.send_text(json.dumps({"type": "error", "error": str(exc)}))
                    continue
                if control.get("type") == "clear_source":
                    _faceswap_engine.clear_source(effective_session)
                    await ws.send_text(json.dumps({"type": "source_face_cleared"}))
                    continue
                if control.get("type") == "ping":
                    await ws.send_text(json.dumps({"type": "pong"}))
                    continue
                continue

            data = message.get("bytes")
            if data is None:
                continue
            try:
                out_bytes, process_ms = await process_image_locally(data, effective_session)
            except HTTPException as exc:
                await ws.send_text(json.dumps({"type": "error", "error": exc.detail}))
                continue
            # Send timing before the binary response.  The mobile app uses this
            # to distinguish network delay from GPU delay and to tune capture
            # rate without guessing.
            await ws.send_text(json.dumps({"type": "frame_meta", "process_ms": process_ms}))
            await broadcast_processed_frame(session_id, out_bytes)
            await ws.send_bytes(out_bytes)
    except WebSocketDisconnect:
        # Keep the source for named sessions so a temporary mobile-network
        # reconnect can resume immediately. Ephemeral sockets are cleaned up.
        if not session_id:
            _faceswap_engine.clear_source(effective_session)
        logger.info("WebSocket disconnected")
    except Exception:
        if not session_id:
            _faceswap_engine.clear_source(effective_session)
        logger.exception("WebSocket error")
        await ws.close()


@app.exception_handler(HTTPException)
async def http_exception_handler(_: Request, exc: HTTPException):
    return JSONResponse(status_code=exc.status_code, content={"detail": exc.detail})