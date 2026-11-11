"""SoundCloud AAC HLS bitrate negotiation for Nightwell Music.

Uses official SoundCloud OAuth, track resolution and /tracks/{urn}/streams.
No audio re-encoding, no artificial "320k". Existing /api/stream serves as an
explicit fallback when the original server cannot resolve official variants.
Only track IDs found in the signed-in user's /api/tracks catalogue are resolved.
Requires NW_SC_CLIENT_ID + NW_SC_CLIENT_SECRET for public licensed playback.

Routes:
GET /api/audio-quality/options?track_id=<id>&quality=auto|economy|high
GET /api/audio-quality/stream/<id>?quality=auto|economy|high&format=hls|file

A JSON options response includes requested_quality, selected_quality,
actual_kbps, fallback, message and source. A JSON response is the
authoritative playback-quality notice shown by clients. Redirects to known
SoundCloud media hosts are made only for playable authorized tracks.
"""
import asyncio
import base64
import hashlib
import inspect
import os
import re
import time
from urllib.parse import urlsplit

import httpx
from fastapi import HTTPException, Request
from fastapi.responses import RedirectResponse

TRACK_ID = re.compile(r"^[A-Za-z0-9_-]{1,80}$")
SC_URN = re.compile(r"^(?:soundcloud:tracks:)?([0-9]{1,20})$")
REQUESTED_QUALITY = ("auto", "economy", "high")
VARIANTS = {"economy": ("hls_aac_96_url", 96), "high": ("hls_aac_160_url", 160)}
SC_API = "https://api.soundcloud.com"
SC_AUTH = "https://secure.soundcloud.com/oauth/token"
PLAYER_HOST = "playback.media-streaming.soundcloud.cloud"


def permitted_soundcloud_permalink(value):
    if not isinstance(value, str) or len(value) > 2048:
        return False
    try:
        parts = urlsplit(value)
    except ValueError:
        return False
    return parts.scheme == "https" and (parts.hostname or "").lower() in {
        "soundcloud.com", "www.soundcloud.com", "m.soundcloud.com",
    } and not (parts.username or parts.password or parts.port)


def safe_media_url(value):
    if not isinstance(value, str) or len(value) > 8192:
        return False
    try:
        parts = urlsplit(value)
        host = (parts.hostname or "").lower()
        return (
            parts.scheme == "https" and parts.username is None and parts.password is None
            and parts.port in (None, 443)
            and (host == PLAYER_HOST or host == "cf-hls-media.sndcdn.com")
            and parts.path.endswith(".m3u8")
        )
    except ValueError:
        return False


def choose(streams, preferred):
    """Return (quality, bitrate, url, fallback) using ONLY offered AAC renditions."""
    if preferred not in REQUESTED_QUALITY:
        raise ValueError("Unsupported quality")
    order = ("high", "economy") if preferred in ("auto", "high") else ("economy", "high")
    for quality in order:
        key, kbps = VARIANTS[quality]
        url = streams.get(key) if isinstance(streams, dict) else None
        if safe_media_url(url):
            return quality, kbps, url, preferred != "auto" and quality != preferred
    return None, None, None, True


class SoundCloudQuality:
    def __init__(self, app, identity, token_provider=None, streams_provider=None, track_provider=None):
        self.app, self.identity = app, identity
        self.token_provider = token_provider
        self.streams_provider = streams_provider
        self.track_provider = track_provider
        self.token = None
        self.token_expiry = 0.0
        self.token_lock = asyncio.Lock()
        self.cached = {}
        self.cache_lock = asyncio.Lock()
        self.inflight = {}

    async def account(self, request):
        value = self.identity(request)
        if inspect.isawaitable(value):
            value = await value
        if not value:
            raise HTTPException(401, detail="Требуется вход в Nightwell Music")
        return hashlib.sha256(("nw-audio-quality:" + str(value)).encode()).hexdigest()

    async def official_token(self):
        if self.token_provider is not None:
            result = self.token_provider()
            return await result if inspect.isawaitable(result) else result
        if self.token and self.token_expiry > time.monotonic() + 90:
            return self.token
        async with self.token_lock:
            if self.token and self.token_expiry > time.monotonic() + 90:
                return self.token
            client_id = os.environ.get("NW_SC_CLIENT_ID", "").strip()
            client_secret = os.environ.get("NW_SC_CLIENT_SECRET", "").strip()
            if not (client_id and client_secret):
                return None
            encoded = base64.b64encode((client_id + ":" + client_secret).encode()).decode()
            async with httpx.AsyncClient(timeout=8) as client:
                response = await client.post(SC_AUTH, data={"grant_type": "client_credentials"},
                    headers={"Authorization": "Basic " + encoded, "Accept": "application/json"})
                response.raise_for_status()
                body = response.json()
            token = body.get("access_token")
            if not isinstance(token, str) or not token:
                return None
            self.token = token
            self.token_expiry = time.monotonic() + max(120, min(3600, int(body.get("expires_in") or 3600))) - 60
            return token

    async def track_for(self, request, track_id):
        if self.track_provider is not None:
            value = self.track_provider(request, track_id)
            return await value if inspect.isawaitable(value) else value
        # Only the logged-in user's own catalogue can authorize a track lookup.
        headers = {
            key: value for key, value in request.headers.items()
            if key.lower() in ("cookie", "x-csrf-token", "origin")
        }
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=self.app),
            base_url="http://nightwell.internal", headers=headers, timeout=6.5,
        ) as client:
            response = await client.get("/api/tracks")
            if response.status_code != 200:
                return None
            data = response.json()
        if not isinstance(data, dict) or not isinstance(data.get("tracks"), list):
            return None
        for item in data["tracks"][:5000]:
            if isinstance(item, dict) and item.get("id") == track_id:
                return item
        return None

    async def streams_for(self, track, token):
        if self.streams_provider is not None:
            value = self.streams_provider(track, token)
            return await value if inspect.isawaitable(value) else value
        if not token:
            return {}
        urn = track.get("soundcloud_urn") or track.get("soundcloud_id")
        urn_match = SC_URN.fullmatch(str(urn)) if urn else None
        headers = {"Authorization": "OAuth " + token, "Accept": "application/json"}
        async with httpx.AsyncClient(timeout=8, follow_redirects=False) as client:
            if urn_match:
                urn = "soundcloud:tracks:" + urn_match.group(1)
            elif permitted_soundcloud_permalink(track.get("source_url")):
                result = await client.get(SC_API + "/resolve",
                    params={"url": track["source_url"]}, headers=headers)
                result.raise_for_status()
                payload = result.json()
                if payload.get("access") not in (None, "playable"):
                    return {}
                urn = payload.get("urn") or payload.get("id")
                urn_match = SC_URN.fullmatch(str(urn)) if urn else None
                if not urn_match:
                    return {}
                urn = "soundcloud:tracks:" + urn_match.group(1)
            else:
                return {}
            response = await client.get(SC_API + "/tracks/" + urn + "/streams", headers=headers)
            if response.status_code in (401, 403, 404):
                return {}
            response.raise_for_status()
            return response.json()

    async def selected(self, request, owner, track_id, quality):
        marker = (owner, track_id, quality)
        async with self.cache_lock:
            cached = self.cached.get(marker)
            if cached and cached[0] > time.monotonic():
                return cached[1]
            task = self.inflight.get(marker)
            if task is None:
                task = asyncio.create_task(
                    self._selected_uncached(request, owner, track_id, quality))
                self.inflight[marker] = task
                # A disconnected client must not keep a completed task in
                # memory. Clear in-flight state even if all waiters cancel.
                def cleanup(done, key=marker):
                    if self.inflight.get(key) is done:
                        self.inflight.pop(key, None)
                task.add_done_callback(cleanup)
        return await asyncio.shield(task)

    async def _selected_uncached(self, request, owner, track_id, quality):
        marker = (owner, track_id, quality)
        track = await self.track_for(request, track_id)
        if not isinstance(track, dict):
            return self.status(quality, None, None, None, "Трек не найден в доступном каталоге", "original")
        source = str(track.get("source", "")).lower()
        source_url = track.get("source_url")
        is_sc = ("soundcloud" in source or permitted_soundcloud_permalink(source_url)
                 or track.get("soundcloud_urn") or track.get("soundcloud_id"))
        if not is_sc:
            return self.status(quality, None, None, None,
                               "Для этого источника доступен исходный поток", "original")
        try:
            token = await self.official_token()
            streams = await self.streams_for(track, token)
            selected, kbps, url, fallback = choose(streams, quality)
        except (httpx.HTTPError, ValueError, TypeError, KeyError):
            selected, kbps, url, fallback = None, None, None, True
        if selected:
            message = ""
            if fallback:
                message = "Качество " + ("96" if quality == "economy" else "160") + \
                          " кбит/с недоступно. Воспроизводится доступное AAC " + str(kbps) + " кбит/с."
            result = self.status(quality, selected, kbps, url, message, "soundcloud", fallback)
            self.cached[marker] = (time.monotonic() + 45, result)
            if len(self.cached) > 1200:
                self.cached = {k:v for k,v in self.cached.items() if v[0] > time.monotonic()}
            return result
        result = self.status(quality, None, None, None,
                             "Качество SoundCloud не удалось определить. "
                             "Воспроизводится обычный доступный поток.", "original")
        self.cached[marker] = (time.monotonic() + 10, result)
        return result

    @staticmethod
    def status(requested, selected, kbps, url, message, source, fallback=True):
        return {
            "requested_quality": requested,
            "selected_quality": selected or "original",
            "actual_kbps": kbps,
            "fallback": bool(fallback),
            "message": message,
            "source": source,
            "stream_url": url,
        }


def install(app, identity, track_provider=None, token_provider=None, streams_provider=None):
    """Install authenticated quality selection without replacing /api/stream."""
    service = SoundCloudQuality(app, identity, token_provider, streams_provider, track_provider)

    async def checked(request, track_id, quality):
        if not TRACK_ID.fullmatch(track_id) or quality not in REQUESTED_QUALITY:
            raise HTTPException(400, detail="Неверный трек или качество")
        owner = await service.account(request)
        result = await service.selected(request, owner, track_id, quality)
        return result

    @app.get("/api/audio-quality/options")
    async def quality_options(request: Request, track_id: str = "", quality: str = "auto"):
        if not track_id:
            await service.account(request)
            return {"options": [
                {"id": "auto", "label": "Авто", "target_kbps": None},
                {"id": "economy", "label": "Экономия", "target_kbps": 96},
                {"id": "high", "label": "Высокое", "target_kbps": 160},
            ], "source": "soundcloud", "selected_quality": "auto"}
        result = await checked(request, track_id, quality)
        return {k: v for k, v in result.items() if k != "stream_url"}

    @app.get("/api/audio-quality/stream/{track_id}")
    async def quality_stream(request: Request, track_id: str,
                             quality: str = "auto", format: str = "hls"):
        if format not in ("hls", "file"):
            raise HTTPException(400, detail="Неверный формат")
        result = await checked(request, track_id, quality)
        if result["source"] == "soundcloud" and result["stream_url"]:
            return RedirectResponse(result["stream_url"], status_code=307,
                headers={
                    "X-NW-Audio-Quality": result["selected_quality"],
                    "Cache-Control": "private, no-store",
                })
        # Legacy source and non-SoundCloud tracks: no fake bitrate declarations.
        return RedirectResponse("/api/stream/" + track_id + "?cache=1&format=" + format,
            status_code=307, headers={
                "X-NW-Audio-Quality": "original",
                "Cache-Control": "private, no-store",
            })

    return service
