"""GPU face-swap inference engine.

Uses InsightFace + ONNX Runtime when the operator supplies the required models.
The engine is intentionally isolated from FastAPI so it can be replaced later
with another licensed model without changing the API contract.
"""
from __future__ import annotations

import os
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Optional

import cv2
import numpy as np


@dataclass
class EngineConfig:
    model_dir: str = os.getenv("MODEL_DIR", "/workspace/model/checkpoints")
    inswapper_model: str = os.getenv("INSWAPPER_MODEL", "inswapper_128.onnx")
    face_analysis_name: str = os.getenv("FACE_ANALYSIS_NAME", "buffalo_l")
    det_size: int = int(os.getenv("FACE_DET_SIZE", "256"))
    providers: tuple[str, ...] = ("CUDAExecutionProvider", "CPUExecutionProvider")
    jpeg_quality: int = int(os.getenv("OUTPUT_JPEG_QUALITY", "72"))
    track_iou_threshold: float = float(os.getenv("TRACK_IOU_THRESHOLD", "0.12"))
    track_center_threshold: float = float(os.getenv("TRACK_CENTER_THRESHOLD", "0.38"))
    track_max_misses: int = int(os.getenv("TRACK_MAX_MISSES", "3"))


class FaceSwapEngine:
    def __init__(self, config: Optional[EngineConfig] = None):
        self.config = config or EngineConfig()
        # Avoid OpenCV spawning a large CPU thread pool beside CUDA inference.
        # On small GPU pods this reduces jitter between frames.
        cv2.setNumThreads(max(1, int(os.getenv("OPENCV_THREADS", "1"))))
        self._app = None
        self._swapper = None
        self._lock = threading.RLock()
        self._source_faces: Dict[str, object] = {}
        # Per-session target tracking.  We deliberately track only WHICH face
        # to use, not its mouth/landmarks.  Smoothing mouth landmarks makes
        # speech look late; identity tracking prevents face hopping without
        # adding lip-sync lag.
        self._tracks: Dict[str, dict] = {}
        self._initialized = False

    def initialize(self) -> None:
        with self._lock:
            if self._initialized:
                return

            try:
                import insightface
                from insightface.app import FaceAnalysis
            except ImportError as exc:
                raise RuntimeError(
                    "InsightFace is not installed. Run the GPU setup script with "
                    "the face-swap dependencies."
                ) from exc

            model_dir = Path(self.config.model_dir)
            model_dir.mkdir(parents=True, exist_ok=True)
            swapper_path = Path(self.config.inswapper_model)
            if not swapper_path.is_absolute():
                swapper_path = model_dir / swapper_path

            if not swapper_path.exists():
                raise RuntimeError(
                    f"Face-swap model not found: {swapper_path}. "
                    "Place the licensed/operator-supplied model there."
                )

            providers = list(self.config.providers)
            try:
                self._app = FaceAnalysis(
                    name=self.config.face_analysis_name,
                    root=str(model_dir),
                    providers=providers,
                )
                self._app.prepare(ctx_id=0, det_size=(self.config.det_size, self.config.det_size))
                self._swapper = insightface.model_zoo.get_model(
                    str(swapper_path), providers=providers
                )
            except Exception as exc:
                raise RuntimeError(f"Failed to initialize face-swap models: {exc}") from exc

            self._initialized = True

    @staticmethod
    def _largest_face(faces):
        if not faces:
            return None
        return max(faces, key=lambda f: float((f.bbox[2] - f.bbox[0]) * (f.bbox[3] - f.bbox[1])))

    @staticmethod
    def _iou(a, b) -> float:
        ax1, ay1, ax2, ay2 = map(float, a)
        bx1, by1, bx2, by2 = map(float, b)
        ix1, iy1 = max(ax1, bx1), max(ay1, by1)
        ix2, iy2 = min(ax2, bx2), min(ay2, by2)
        iw, ih = max(0.0, ix2 - ix1), max(0.0, iy2 - iy1)
        inter = iw * ih
        aa = max(1.0, (ax2-ax1)*(ay2-ay1))
        bb = max(1.0, (bx2-bx1)*(by2-by1))
        return inter / max(1.0, aa + bb - inter)

    @staticmethod
    def _center_distance_norm(a, b, width: int, height: int) -> float:
        acx, acy = (float(a[0])+float(a[2]))/2, (float(a[1])+float(a[3]))/2
        bcx, bcy = (float(b[0])+float(b[2]))/2, (float(b[1])+float(b[3]))/2
        dx, dy = (acx-bcx)/max(1,width), (acy-bcy)/max(1,height)
        return float((dx*dx + dy*dy) ** 0.5)

    def _select_tracked_face(self, session_id: str, faces, width: int, height: int):
        if not faces:
            with self._lock:
                tr = self._tracks.get(session_id)
                if tr:
                    tr['misses'] = int(tr.get('misses', 0)) + 1
                    if tr['misses'] > self.config.track_max_misses:
                        self._tracks.pop(session_id, None)
            return None

        with self._lock:
            previous = self._tracks.get(session_id)

        selected = None
        if previous is not None:
            prev_box = previous['bbox']
            ranked = []
            for face in faces:
                iou = self._iou(prev_box, face.bbox)
                dist = self._center_distance_norm(prev_box, face.bbox, width, height)
                # Favor geometric continuity heavily so another person walking
                # into frame does not steal the swap target.
                score = iou * 3.0 - dist
                ranked.append((score, iou, dist, face))
            ranked.sort(key=lambda x: x[0], reverse=True)
            _, iou, dist, candidate = ranked[0]
            if iou >= self.config.track_iou_threshold or dist <= self.config.track_center_threshold:
                selected = candidate

        if selected is None:
            selected = self._largest_face(faces)

        with self._lock:
            self._tracks[session_id] = {
                'bbox': np.asarray(selected.bbox, dtype=np.float32).copy(),
                'misses': 0,
            }
        return selected

    def set_source(self, session_id: str, image_bytes: bytes) -> dict:
        self.initialize()
        image = cv2.imdecode(np.frombuffer(image_bytes, dtype=np.uint8), cv2.IMREAD_COLOR)
        if image is None:
            raise ValueError("Invalid source image")
        faces = self._app.get(image)
        source_face = self._largest_face(faces)
        if source_face is None:
            raise ValueError("No face found in source image")
        with self._lock:
            self._source_faces[session_id] = source_face
        return {"ok": True, "faces": len(faces)}

    def clear_source(self, session_id: str) -> None:
        with self._lock:
            self._source_faces.pop(session_id, None)
            self._tracks.pop(session_id, None)

    def process(self, session_id: str, image_bytes: bytes, quality: Optional[int] = None) -> bytes:
        self.initialize()
        with self._lock:
            source_face = self._source_faces.get(session_id)
        if source_face is None:
            raise ValueError("Source face is not set for this session")

        target = cv2.imdecode(np.frombuffer(image_bytes, dtype=np.uint8), cv2.IMREAD_COLOR)
        if target is None:
            raise ValueError("Invalid target frame")

        faces = self._app.get(target)
        target_face = self._select_tracked_face(
            session_id, faces, target.shape[1], target.shape[0]
        )
        if target_face is None:
            # Do not paste an old face when tracking is lost. Reusing a stale
            # crop is what creates the visible "floating face" artifact.
            output = target
        else:
            output = self._swapper.get(target, target_face, source_face, paste_back=True)

        encode_quality = int(quality if quality is not None else self.config.jpeg_quality)
        ok, encoded = cv2.imencode(".jpg", output, [int(cv2.IMWRITE_JPEG_QUALITY), encode_quality])
        if not ok:
            raise RuntimeError("Failed to encode output frame")
        return encoded.tobytes()

    def status(self) -> dict:
        return {
            "initialized": self._initialized,
            "model": self.config.inswapper_model,
            "model_dir": self.config.model_dir,
            "active_source_sessions": len(self._source_faces),
            "det_size": self.config.det_size,
            "jpeg_quality": self.config.jpeg_quality,
            "active_tracks": len(self._tracks),
            "track_iou_threshold": self.config.track_iou_threshold,
            "track_max_misses": self.config.track_max_misses,
        }
