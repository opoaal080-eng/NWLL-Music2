"""Optional low-latency audio quality endpoint for an existing Nightwell FastAPI server.

GET /api/audio-quality/options
GET /api/audio-quality/stream/{track_id}?quality=original|economy|balanced|high&format=file|hls
POST /api/audio-quality/prewarm  {"tracks": ["id1", "id2"], "quality": "balanced"}

Does not replace /api/stream. Cache miss -> immediate original-stream redirect,
then opportunistic single-worker transcode into an account-scoped AAC cache.
The client must opt into the new route for this quality selection to take effect.
"""
import asyncio
import hashlib
import inspect
import json
import os
from pathlib import Path
import re
import shutil
import time

from fastapi import HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse

QUALITY = {"original": None, "economy": 96, "balanced": 160, "high": 256}
TRACK_ID = re.compile(r"^[A-Za-z0-9_-]{1,80}$")
MAX_SOURCE_BYTES = 64 * 1024 * 1024
MAX_CACHE_BYTES = 768 * 1024 * 1024
CACHE_MAX_AGE = 14 * 86400


class QualityCache:
    def __init__(self, app, identity, root=None, ffmpeg=None):
        self.app = app
        self.identity = identity
        self.root = Path(root or os.environ.get("NW_AUDIO_QUALITY_CACHE", "data/audio-quality")).resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        executable = ffmpeg or os.environ.get("NW_FFMPEG") or "ffmpeg"
        self.ffmpeg = shutil.which(executable)
        self.semaphore = asyncio.Semaphore(1)
        self.pending = set()
        self.tasks = set()

    @staticmethod
    def validate(track_id, quality, format):
        if not TRACK_ID.fullmatch(track_id):
            raise HTTPException(400, detail="Неверный ID трека")
        if quality not in QUALITY:
            raise HTTPException(400, detail="Качество: original, economy, balanced, high")
        if format not in ("file", "hls"):
            raise HTTPException(400, detail="Формат: file или hls")

    async def owner(self, request):
        value = self.identity(request)
        if inspect.isawaitable(value):
            value = await value
        if not value:
            raise HTTPException(401, detail="Войди в Nightwell Music")
        return hashlib.sha256(("nw-audio-quality:" + str(value)).encode("utf-8")).hexdigest()

    def cached_path(self, owner, track_id, quality):
        name = hashlib.sha256((owner + "|" + track_id + "|" + quality).encode("utf-8")).hexdigest()
        return self.root / (name + ".m4a")

    @staticmethod
    def original_url(track_id, format):
        # No user-controlled URL, host or query is accepted by the proxy.
        return "/api/stream/" + track_id + "?cache=1&format=" + format

    def schedule(self, owner, track_id, quality, headers):
        if not self.ffmpeg or quality == "original":
            return False
        path = self.cached_path(owner, track_id, quality)
        if path.is_file() or len(self.pending) >= 48:
            return False
        key = (owner, track_id, quality)
        if key in self.pending:
            return False
        self.pending.add(key)
        task = asyncio.create_task(self._generate(owner, track_id, quality, headers, key))
        self.tasks.add(task)
        task.add_done_callback(self.tasks.discard)
        return True

    async def _generate(self, owner, track_id, quality, headers, key):
        input_path = None
        output_path = None
        try:
            async with self.semaphore:
                target = self.cached_path(owner, track_id, quality)
                if target.is_file():
                    return
                nonce = hashlib.sha256((key[0] + key[1] + str(time.time_ns())).encode()).hexdigest()[:12]
                input_path = self.root / (nonce + ".input")
                output_path = self.root / (nonce + ".pending.m4a")
                # ASGI transport contacts only this FastAPI app; no network URL or
                # file path may be supplied by the caller, and auth is forwarded.
                import httpx
                async with httpx.AsyncClient(
                    transport=httpx.ASGITransport(app=self.app),
                    base_url="http://nightwell.internal", follow_redirects=False,
                    timeout=35.0,
                ) as client:
                    async with client.stream(
                        "GET", self.original_url(track_id, "file"),
                        headers=headers,
                    ) as response:
                        if response.status_code != 200:
                            return
                        mime = response.headers.get("content-type", "").split(";")[0].strip().lower()
                        if not (mime.startswith("audio/") or mime in
                                ("application/octet-stream", "video/mp4")):
                            return
                        length = response.headers.get("content-length")
                        if length and int(length) > MAX_SOURCE_BYTES:
                            return
                        size = 0
                        with input_path.open("wb") as output:
                            async for block in response.aiter_bytes(65536):
                                size += len(block)
                                if size > MAX_SOURCE_BYTES:
                                    return
                                output.write(block)
                if not input_path.is_file() or input_path.stat().st_size < 1000:
                    return
                proc = await asyncio.create_subprocess_exec(
                    self.ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                    "-i", str(input_path), "-map", "0:a:0", "-vn", "-sn", "-dn",
                    "-c:a", "aac", "-b:a", str(QUALITY[quality]) + "k",
                    "-movflags", "+faststart", "-f", "mp4", str(output_path),
                    stdout=asyncio.subprocess.DEVNULL,
                    stderr=asyncio.subprocess.DEVNULL,
                )
                try:
                    await asyncio.wait_for(proc.wait(), timeout=110)
                except asyncio.TimeoutError:
                    proc.kill()
                    await proc.wait()
                    return
                if proc.returncode != 0 or not output_path.is_file() or output_path.stat().st_size < 1000:
                    return
                os.replace(output_path, target)
                await asyncio.to_thread(self.trim_cache)
        except (OSError, ValueError, asyncio.CancelledError):
            return
        except Exception:
            # A cache miss is never a playback error. The original source keeps playing.
            return
        finally:
            for path in (input_path, output_path):
                if path is not None:
                    try:
                        path.unlink(missing_ok=True)
                    except OSError:
                        pass
            self.pending.discard(key)

    def trim_cache(self):
        now = time.time()
        entries = []
        for file in self.root.glob("*.m4a"):
            try:
                stat = file.stat()
                if now - stat.st_mtime > CACHE_MAX_AGE:
                    file.unlink(missing_ok=True)
                else:
                    entries.append((stat.st_mtime, stat.st_size, file))
            except OSError:
                pass
        total = sum(size for _, size, _ in entries)
        if total > MAX_CACHE_BYTES:
            for _, size, file in sorted(entries):
                if total <= MAX_CACHE_BYTES:
                    break
                try:
                    file.unlink()
                    total -= size
                except OSError:
                    pass


def install(app, identity, cache_root=None, ffmpeg=None):
    """Attach optional endpoints after the existing authenticated stream routes."""
    cache = QualityCache(app, identity, root=cache_root, ffmpeg=ffmpeg)

    @app.get("/api/audio-quality/options")
    async def quality_options(request: Request):
        await cache.owner(request)
        return {
            "options": [
                {"id": name, "target_kbps": rate}
                for name, rate in QUALITY.items()
            ],
            "ffmpeg_available": bool(cache.ffmpeg),
            "original_on_miss": True,
            "message": "Первое воспроизведение идёт без задержки в исходном качестве. "
                       "AAC-вариант появляется после фонового приготовления.",
        }

    @app.get("/api/audio-quality/stream/{track_id}")
    async def quality_stream(
        request: Request, track_id: str,
        quality: str = "original", format: str = "file",
    ):
        cache.validate(track_id, quality, format)
        owner = await cache.owner(request)
        original = cache.original_url(track_id, format)
        if quality == "original" or format == "hls":
            return RedirectResponse(original, status_code=307, headers={
                "X-NW-Audio-Quality": "original"})
        path = cache.cached_path(owner, track_id, quality)
        if path.is_file() and path.stat().st_size > 1000:
            return FileResponse(
                path, media_type="audio/mp4",
                headers={"Cache-Control": "private, max-age=300",
                         "X-NW-Audio-Quality": quality},
            )
        headers = {
            key: value for key, value in request.headers.items()
            if key.lower() in ("cookie", "x-csrf-token")
        }
        cache.schedule(owner, track_id, quality, headers)
        # Playback is NEVER blocked by encoding. A high quality request with no
        # cached variant gets the real original, not an upscaled placeholder.
        return RedirectResponse(original, status_code=307, headers={
            "X-NW-Audio-Quality": "original-pending"})

    @app.post("/api/audio-quality/prewarm")
    async def quality_prewarm(request: Request):
        owner = await cache.owner(request)
        try:
            body = await request.json()
        except (ValueError, json.JSONDecodeError):
            raise HTTPException(400, detail="Ожидается JSON")
        if not isinstance(body, dict):
            raise HTTPException(400, detail="Ожидается объект")
        quality = body.get("quality", "balanced")
        tracks = body.get("tracks", [])
        if quality not in QUALITY or quality == "original":
            raise HTTPException(400, detail="Укажи economy, balanced или high")
        if not isinstance(tracks, list) or len(tracks) > 5:
            raise HTTPException(400, detail="До пяти треков за запрос")
        headers = {
            key: value for key, value in request.headers.items()
            if key.lower() in ("cookie", "x-csrf-token")
        }
        scheduled = 0
        for track_id in set(tracks):
            if not isinstance(track_id, str) or not TRACK_ID.fullmatch(track_id):
                raise HTTPException(400, detail="Неверный ID трека")
            if cache.schedule(owner, track_id, quality, headers):
                scheduled += 1
        return {"queued": scheduled, "ffmpeg_available": bool(cache.ffmpeg)}

    return cache
