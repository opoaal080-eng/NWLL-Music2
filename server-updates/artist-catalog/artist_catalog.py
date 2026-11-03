"""Nightwell artist directory: private account-scoped index of playable catalogue metadata.

Mount with install(app, identity, db_path). Works with existing /api/tracks endpoints.
Artist photographs come only from the operator's authorized cloud-image mapping.
No SoundCloud scraping, API calls or reuse of track cover art.
"""
import asyncio
import hashlib
import inspect
import json
import os
import re
import sqlite3
import time
import unicodedata
from pathlib import Path
from urllib.parse import urlsplit

from fastapi import HTTPException, Request

MAX_TRACKS_PER_RESPONSE = 3000
MAX_PROFILE_TRACKS = 500
MAX_QUERY_CHARS = 120


def normalized(value):
    value = unicodedata.normalize("NFKC", str(value or "")).casefold().replace("ё", "е")
    return " ".join(re.findall(r"[^\W_]+", value, re.UNICODE))


def split_artists(value):
    if not isinstance(value, str):
        return []
    value = re.sub(r"(?i)[\(\[]\s*(?:feat\.?|ft\.?|featuring)\s+", ", ", value)
    value = re.sub(r"(?i)\s+(?:feat\.?|ft\.?|featuring|&|×|x)\s+", ", ", value)
    value = re.sub(r"[\)\]]", "", value)
    result, seen = [], set()
    for item in value.split(","):
        name = item.strip()
        key = normalized(name)
        if key and len(name) <= 160 and key not in seen:
            result.append(name)
            seen.add(key)
    return result[:10]


def artist_id(name):
    return hashlib.sha256(("nightwell-artist:" + normalized(name)).encode()).hexdigest()[:24]


def safe_image_url(url, allowed_hosts):
    if not isinstance(url, str) or len(url) > 2048:
        return None
    try:
        parts = urlsplit(url)
        host = (parts.hostname or "").lower()
        if (parts.scheme != "https" or not host or host not in allowed_hosts or
                parts.username or parts.password or parts.port not in (None, 443)):
            return None
        return url
    except ValueError:
        return None


class ArtistDirectory:
    def __init__(self, db_path, image_map=None, image_hosts=None):
        self.db_path = Path(db_path)
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self.image_map_path = Path(image_map) if image_map else None
        self.image_hosts = {v.strip().lower() for v in (image_hosts or []) if v.strip()}
        self._images = {}
        self._image_updated = 0
        self._lookups = {}
        self._lookup_lock = asyncio.Lock()
        with self.connect() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS artist_directory_tracks (
                    owner TEXT NOT NULL, track_id TEXT NOT NULL, payload TEXT NOT NULL,
                    updated REAL NOT NULL, PRIMARY KEY(owner, track_id));
                CREATE TABLE IF NOT EXISTS artist_directory_artists (
                    owner TEXT NOT NULL, artist_id TEXT NOT NULL, name TEXT NOT NULL,
                    name_key TEXT NOT NULL, PRIMARY KEY(owner, artist_id));
                CREATE INDEX IF NOT EXISTS idx_directory_artist_search
                    ON artist_directory_artists(owner, name_key);
                CREATE TABLE IF NOT EXISTS artist_directory_artist_tracks (
                    owner TEXT NOT NULL, artist_id TEXT NOT NULL, track_id TEXT NOT NULL,
                    PRIMARY KEY(owner, artist_id, track_id));
                CREATE INDEX IF NOT EXISTS idx_directory_artist_tracks_track
                    ON artist_directory_artist_tracks(owner, track_id);
            """)

    def connect(self):
        db = sqlite3.connect(str(self.db_path), timeout=8)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA busy_timeout=8000")
        return db

    def owner_key(self, account):
        return hashlib.sha256(("nw-directory:" + str(account)).encode()).hexdigest()

    def record(self, owner, items):
        count = 0
        if not isinstance(items, list):
            return count
        with self.connect() as db:
            for item in items[:MAX_TRACKS_PER_RESPONSE]:
                if not isinstance(item, dict):
                    continue
                tid, title, artist = item.get("id"), item.get("title"), item.get("artist")
                if (not isinstance(tid, str) or not 1 <= len(tid) <= 128 or
                        not isinstance(title, str) or not 1 <= len(title.strip()) <= 300 or
                        not isinstance(artist, str) or not 1 <= len(artist.strip()) <= 300):
                    continue
                names = split_artists(artist)
                if not names:
                    continue
                public = {k: item[k] for k in
                          ("id", "title", "artist", "album", "duration", "cover_url",
                           "source", "source_url", "is_remote")
                          if k in item and isinstance(item[k], (str, int, float, bool, type(None)))}
                if isinstance(public.get("cover_url"), str) and len(public["cover_url"]) > 2048:
                    public.pop("cover_url")
                db.execute(
                    "INSERT INTO artist_directory_tracks(owner,track_id,payload,updated) "
                    "VALUES (?,?,?,?) ON CONFLICT(owner,track_id) DO UPDATE SET "
                    "payload=excluded.payload,updated=excluded.updated",
                    (owner, tid, json.dumps(public, ensure_ascii=False, allow_nan=False), time.time()))
                db.execute("DELETE FROM artist_directory_artist_tracks WHERE owner=? AND track_id=?",
                           (owner, tid))
                for name in names:
                    aid, key = artist_id(name), normalized(name)
                    db.execute(
                        "INSERT INTO artist_directory_artists(owner,artist_id,name,name_key) "
                        "VALUES (?,?,?,?) ON CONFLICT(owner,artist_id) DO UPDATE SET name=excluded.name",
                        (owner, aid, name, key))
                    db.execute("INSERT OR IGNORE INTO artist_directory_artist_tracks VALUES (?,?,?)",
                               (owner, aid, tid))
                count += 1
            # Artist records left orphaned after metadata updates are dropped.
            db.execute(
                "DELETE FROM artist_directory_artists WHERE owner=? AND NOT EXISTS "
                "(SELECT 1 FROM artist_directory_artist_tracks r WHERE "
                "r.owner=artist_directory_artists.owner AND "
                "r.artist_id=artist_directory_artists.artist_id)", (owner,))
        return count

    def refresh_image_map(self):
        if not self.image_map_path or not self.image_map_path.is_file():
            self._images = {}
            return
        try:
            stamp = self.image_map_path.stat().st_mtime_ns
            if stamp == self._image_updated:
                return
            data = json.loads(self.image_map_path.read_text(encoding="utf-8"))
            if not isinstance(data, dict):
                return
            clean = {}
            for name, value in list(data.items())[:50000]:
                key = normalized(name)
                url = safe_image_url(value, self.image_hosts)
                if key and url:
                    clean[key] = url
            self._images, self._image_updated = clean, stamp
        except (OSError, ValueError, json.JSONDecodeError):
            # A bad config must never break music playback or artist search.
            pass

    def item(self, row):
        self.refresh_image_map()
        return {
            "id": row["artist_id"], "name": row["name"],
            "image_url": self._images.get(row["name_key"]),
            "track_count": int(row["cnt"]), "source": "nightwell"
        }

    def search(self, owner, q, limit=16):
        key = normalized(q)
        if len(key) < 2:
            return []
        with self.connect() as db:
            rows = db.execute("""
                SELECT a.artist_id, a.name, a.name_key, COUNT(r.track_id) AS cnt
                FROM artist_directory_artists a
                JOIN artist_directory_artist_tracks r
                    ON r.owner=a.owner AND r.artist_id=a.artist_id
                WHERE a.owner=? AND a.name_key LIKE ? ESCAPE '!'
                GROUP BY a.artist_id, a.name, a.name_key
                ORDER BY CASE WHEN a.name_key=? THEN 0
                              WHEN a.name_key LIKE ? ESCAPE '!' THEN 1 ELSE 2 END,
                         cnt DESC, a.name_key
                LIMIT ?
            """, (owner, "%" + key.replace("!", "!!").replace("%", "!%").replace("_", "!_") + "%",
                   key, key.replace("!", "!!").replace("%", "!%").replace("_", "!_") + "%", min(50, max(1, int(limit))))).fetchall()
        return [self.item(row) for row in rows]

    def profile(self, owner, name):
        key = normalized(name)
        if not key:
            return None
        with self.connect() as db:
            row = db.execute("""
                SELECT a.artist_id, a.name, a.name_key, COUNT(r.track_id) AS cnt
                FROM artist_directory_artists a
                JOIN artist_directory_artist_tracks r
                    ON r.owner=a.owner AND r.artist_id=a.artist_id
                WHERE a.owner=? AND a.artist_id=?
                GROUP BY a.artist_id, a.name, a.name_key
            """, (owner, artist_id(name))).fetchone()
            if not row:
                return None
            tracks = db.execute("""
                SELECT t.payload FROM artist_directory_artist_tracks r
                JOIN artist_directory_tracks t ON t.owner=r.owner AND t.track_id=r.track_id
                WHERE r.owner=? AND r.artist_id=?
                ORDER BY t.updated DESC LIMIT ?
            """, (owner, row["artist_id"], MAX_PROFILE_TRACKS)).fetchall()
        return {"artist": self.item(row), "tracks": [json.loads(x["payload"]) for x in tracks],
                "total": int(row["cnt"])}

    def should_refresh(self, owner, q, ttl=60):
        marker = (owner, normalized(q))
        now = time.monotonic()
        if self._lookups.get(marker, 0) > now:
            return False
        if len(self._lookups) > 3000:
            self._lookups = {k: v for k, v in self._lookups.items() if v > now}
        self._lookups[marker] = now + ttl
        return True


def install(app, identity, db_path, image_map=None, image_hosts=None):
    """Mount GET /api/artists and /api/artists/profile onto an existing FastAPI app.

    identity(request) must return the current account ID or None. No data is shared
    across accounts. The existing /api/tracks remains the only playable-track source.
    """
    if image_hosts is None:
        image_hosts = os.environ.get("NW_ARTIST_IMAGE_HOSTS", "").split(",")
    if image_map is None:
        image_map = os.environ.get("NW_ARTIST_IMAGE_MAP")
    directory = ArtistDirectory(db_path, image_map=image_map, image_hosts=image_hosts)

    async def account_for(request):
        account = identity(request)
        if inspect.isawaitable(account):
            account = await account
        if not account:
            raise HTTPException(status_code=401, detail="Войди в Nightwell Music")
        return directory.owner_key(account)

    async def ingest(request, owner, q):
        if not directory.should_refresh(owner, q):
            return
        # Call the existing API through ASGI, forwarding only session headers,
        # never fetching an arbitrary remote URL or touching private files.
        import httpx
        headers = {k: v for k, v in request.headers.items()
                   if k.lower() in ("cookie", "x-csrf-token", "origin")}
        try:
            async with httpx.AsyncClient(
                transport=httpx.ASGITransport(app=app), base_url=str(request.base_url),
                headers=headers, timeout=10
            ) as client:
                response = await client.get("/api/tracks", params={"q": q} if q else None)
            if response.status_code != 200:
                return
            tracks = response.json().get("tracks", [])
            await asyncio.to_thread(directory.record, owner, tracks)
        except (httpx.HTTPError, ValueError, TypeError):
            return

    @app.get("/api/artists")
    async def artists(request: Request, q: str = "", limit: int = 16):
        owner = await account_for(request)
        q = q.strip()
        if not 2 <= len(q) <= MAX_QUERY_CHARS:
            return {"artists": []}
        # First request also indexes the user's visible catalogue. Cached later.
        if directory.should_refresh(owner, "__initial_catalog__", ttl=600):
            await asyncio.gather(ingest(request, owner, ""), ingest(request, owner, q))
        else:
            await ingest(request, owner, q)
        return {"artists": await asyncio.to_thread(directory.search, owner, q, limit)}

    @app.get("/api/artists/profile")
    async def artist_profile(request: Request, name: str = ""):
        owner = await account_for(request)
        name = name.strip()
        if not 1 <= len(name) <= MAX_QUERY_CHARS:
            raise HTTPException(status_code=400, detail="Укажи исполнителя")
        await ingest(request, owner, name)
        profile = await asyncio.to_thread(directory.profile, owner, name)
        if not profile:
            raise HTTPException(status_code=404, detail="Исполнитель не найден")
        return profile

    return directory
