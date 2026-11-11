"""Optional, low-load YouTube clip lookup. YouTube videos are never proxied or stored."""
import asyncio
from collections import OrderedDict
import html
import json
import os
from pathlib import Path
import re
import time
from datetime import datetime, timezone
from urllib.parse import urlencode
from urllib.request import Request as URLRequest, urlopen

from fastapi import HTTPException, Request

BASE_URL = "https://www.googleapis.com/youtube/v3/search"
# YouTube Data API search costs 100 quota units. Keep a headroom buffer
# below the standard 10,000-units/day key quota.
MAX_SEARCHES_PER_DAY = 80
MAX_CACHE_ENTRIES = 3000
POSITIVE_TTL = 12 * 60 * 60
NEGATIVE_TTL = 5 * 60
VERSIONS = {"remix", "live", "cover", "instrumental", "karaoke", "sped", "slowed"}


def normalized(text):
    text = html.unescape(str(text or "")).casefold().replace("ё", "е")
    return " ".join(re.findall(r"[^\W_]+", text, flags=re.UNICODE))


def choose_video(items, title, artist):
    """Conservative: don't advertise fan edits, remixes or unrelated videos."""
    expected_title = normalized(title)
    expected_artist = normalized(artist)
    if not expected_title or not expected_artist:
        return None
    for item in items[:8]:
        if not isinstance(item, dict):
            continue
        video_id = (item.get("id") or {}).get("videoId")
        snippet = item.get("snippet") or {}
        if not isinstance(video_id, str) or not re.fullmatch(r"[A-Za-z0-9_-]{11}", video_id):
            continue
        video_title = html.unescape(str(snippet.get("title", "")))
        channel = html.unescape(str(snippet.get("channelTitle", "")))
        title_norm = normalized(video_title)
        channel_norm = normalized(channel)
        if expected_title not in title_norm:
            continue
        if expected_artist not in title_norm and expected_artist not in channel_norm:
            continue
        version_difference = set(title_norm.split()) & VERSIONS - set(expected_title.split())
        if version_difference:
            continue
        # A reliable official upload must look like a music video or be
        # published on the named artist's channel.
        video_terms = ("official", "music video", "клип", "официальн", "mv")
        if not any(v in title_norm for v in video_terms) and expected_artist not in channel_norm:
            continue
        return {"available": True, "video_id": video_id,
                "title": video_title[:180], "channel": channel[:100]}
    return None


class ClipLookup:
    def __init__(self):
        self.key = os.environ.get("NW_YOUTUBE_API_KEY", "").strip()
        self.lock = asyncio.Lock()
        self.cache = OrderedDict()
        self.cache_path = Path(os.environ.get(
            "NW_YOUTUBE_CACHE_PATH",
            str(Path(__file__).with_name("nightwell_verified_clips.json"))
        ))
        self._load_verified()
        self.today = ""
        self.count = 0

    def _load_verified(self):
        """Keep already verified YouTube IDs after server process restarts."""
        try:
            payload = json.loads(self.cache_path.read_text(encoding="utf-8"))
            if not isinstance(payload, dict):
                return
            now = time.time()
            for key, item in list(payload.items())[:MAX_CACHE_ENTRIES]:
                if not isinstance(item, dict):
                    continue
                expires = item.get("expires_at")
                response = item.get("response")
                if not isinstance(expires, (int, float)) or expires <= now:
                    continue
                if not isinstance(response, dict) or not response.get("available"):
                    continue
                if not re.fullmatch(r"[A-Za-z0-9_-]{11}", response.get("video_id", "")):
                    continue
                self.cache[key] = (time.monotonic() + expires - now, response)
        except (OSError, ValueError, TypeError):
            pass

    def _save_verified(self):
        """Write only proven matches. Failures and quota errors are never persisted."""
        now = time.monotonic()
        expires = time.time()
        payload = {
            key: {"expires_at": expires + max(0, deadline - now),
                  "response": result}
            for key, (deadline, result) in self.cache.items()
            if deadline > now and result.get("available")
        }
        temporary = self.cache_path.with_name(self.cache_path.name + ".new")
        try:
            self.cache_path.parent.mkdir(parents=True, exist_ok=True)
            temporary.write_text(json.dumps(payload, ensure_ascii=False),
                                 encoding="utf-8")
            os.replace(temporary, self.cache_path)
        except OSError:
            try:
                temporary.unlink(missing_ok=True)
            except OSError:
                pass

    def search_sync(self, title, artist):
        query = (artist + " " + title + " official music video")[:260]
        url = BASE_URL + "?" + urlencode({
            "part": "snippet",
            "type": "video",
            "maxResults": "8",
            "videoEmbeddable": "true",
            "videoSyndicated": "true",
            "q": query,
            "key": self.key
        })
        request = URLRequest(url, headers={"User-Agent": "NightwellMusic/1.0"})
        with urlopen(request, timeout=6) as response:
            payload = response.read(150_000)
        doc = json.loads(payload)
        return choose_video(doc.get("items", []), title, artist)

    async def lookup(self, title, artist):
        if not self.key:
            return {"available": False, "message": "Поиск клипов не настроен"}
        cache_key = normalized(title) + "|" + normalized(artist)
        async with self.lock:
            now = time.monotonic()
            cached = self.cache.get(cache_key)
            if cached and cached[0] > now:
                self.cache.move_to_end(cache_key)
                return cached[1]
            today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
            if today != self.today:
                self.today, self.count = today, 0
            if self.count >= MAX_SEARCHES_PER_DAY:
                return {"available": False, "message": "Лимит поиска клипов исчерпан"}
            self.count += 1
            try:
                result = await asyncio.wait_for(
                    asyncio.to_thread(self.search_sync, title, artist), timeout=8)
                if result is None:
                    result = {"available": False}
                ttl = POSITIVE_TTL if result.get("available") else NEGATIVE_TTL
            except Exception:
                result = {"available": False, "message": "Поиск клипа временно недоступен"}
                ttl = 5 * 60
            self.cache[cache_key] = (time.monotonic() + ttl, result)
            while len(self.cache) > MAX_CACHE_ENTRIES:
                self.cache.popitem(last=False)
            if result.get("available"):
                self._save_verified()
            return result


def install(app, identity):
    """Install on the already authenticated Nightwell FastAPI app."""
    if getattr(app.state, "music_videos_installed", False):
        return
    finder = ClipLookup()

    @app.get("/api/music-videos/clip")
    async def music_clip(request: Request, title: str, artist: str):
        if not identity(request):
            raise HTTPException(401, "Войдите в Nightwell Music")
        if (not title.strip() or not artist.strip()
                or len(title) > 160 or len(artist) > 160):
            raise HTTPException(422, "Некорректное название или исполнитель")
        return await finder.lookup(title.strip(), artist.strip())

    app.state.music_videos_installed = True
