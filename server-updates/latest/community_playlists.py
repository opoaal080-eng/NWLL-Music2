"""Opt-in public playlist discovery for Nightwell Music.

Attach to the existing FastAPI app with install(app, identity, db_path).
Only playlist metadata is published. No music files, cookies or signed stream URLs
are persisted. Publishing verifies the playlist belongs to the current session.
"""
import json
import re
import sqlite3
import time
import uuid
from pathlib import Path
from urllib.parse import quote

import httpx
from fastapi import HTTPException, Request

_ID = re.compile(r"^[A-Za-z0-9_-]{1,128}$")
_FIELDS = ("id", "title", "artist", "album", "duration", "cover_url",
           "source", "is_remote", "performer", "artist_credit", "metadata_artist")
_MAX_TRACKS = 500


def install(app, identity, db_path):
    path = Path(db_path).resolve()
    path.parent.mkdir(parents=True, exist_ok=True)

    def connect():
        conn = sqlite3.connect(str(path), timeout=10)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA busy_timeout=10000")
        conn.execute("""CREATE TABLE IF NOT EXISTS community_playlists (
            id TEXT PRIMARY KEY,
            owner TEXT NOT NULL,
            source_playlist_id TEXT NOT NULL,
            name TEXT NOT NULL,
            search_blob TEXT NOT NULL,
            cover_url TEXT,
            tracks_json TEXT NOT NULL,
            track_count INTEGER NOT NULL,
            published_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            UNIQUE(owner, source_playlist_id))""")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_community_recent ON community_playlists(updated_at DESC)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_community_owner ON community_playlists(owner)")
        return conn

    def require_user(request):
        account = identity(request)
        if not account:
            raise HTTPException(status_code=401, detail="Войди в Nightwell Music")
        return str(account)

    def valid_id(value):
        if not isinstance(value, str) or not _ID.fullmatch(value):
            raise HTTPException(status_code=400, detail="Некорректный ID плейлиста")
        return value

    def client_headers(request):
        # The internal API must see the same authenticated user and CSRF token.
        return {k: v for k, v in request.headers.items()
                if k.lower() in ("cookie", "authorization", "x-csrf-token", "origin")}

    def safe_track(item):
        if not isinstance(item, dict) or not isinstance(item.get("id"), str):
            return None
        key = item["id"]
        if not key or len(key) > 128 or key.startswith("local_") or "/" in key:
            return None
        if not isinstance(item.get("title"), str) or not isinstance(item.get("artist"), str):
            return None
        # All fields are descriptive metadata. Do not expose source_url, offline
        # paths, user tokens, private fields or user-uploaded audio bytes.
        safe = {}
        for field in _FIELDS:
            value = item.get(field)
            if value is None:
                continue
            if field == "duration":
                if isinstance(value, (int, float)) and 0 <= value <= 86400:
                    safe[field] = value
            elif field == "is_remote":
                if isinstance(value, bool):
                    safe[field] = value
            elif isinstance(value, str):
                safe[field] = value[:2048 if field == "cover_url" else 300]
        return safe

    def summary(row, mine=False):
        data = {"id": row["id"], "name": row["name"],
                "author": "Пользователь Nightwell", "count": row["track_count"],
                "cover_url": row["cover_url"], "published_at": row["published_at"]}
        if mine:
            data["source_playlist_id"] = row["source_playlist_id"]
        return data

    async def internal(client, method, endpoint, **kwargs):
        response = await client.request(method, endpoint, **kwargs)
        if response.status_code >= 400:
            raise HTTPException(status_code=502, detail="Сервер не смог обновить плейлист")
        try:
            return response.json()
        except ValueError:
            raise HTTPException(status_code=502, detail="Некорректный ответ сервера")

    @app.get("/api/community-playlists/mine")
    async def my_public_playlists(request: Request):
        owner = require_user(request)
        with connect() as db:
            rows = db.execute(
                "SELECT * FROM community_playlists WHERE owner=? ORDER BY updated_at DESC",
                (owner,)).fetchall()
        return {"playlists": [summary(row, mine=True) for row in rows]}

    @app.get("/api/community-playlists")
    async def find_community_playlists(q: str = "", limit: int = 30):
        query = q.strip().casefold()[:120]
        limit = max(1, min(50, limit))
        with connect() as db:
            if query:
                # Treat % and _ as text, not SQL wildcards.
                pattern = "%" + query.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"
                rows = db.execute(
                    "SELECT * FROM community_playlists WHERE search_blob LIKE ? ESCAPE '\\' "
                    "ORDER BY updated_at DESC LIMIT ?",
                    (pattern, limit)).fetchall()
            else:
                rows = db.execute(
                    "SELECT * FROM community_playlists ORDER BY updated_at DESC LIMIT ?",
                    (limit,)).fetchall()
        return {"playlists": [summary(row) for row in rows]}

    @app.post("/api/community-playlists/publish")
    async def publish_playlist(request: Request):
        owner = require_user(request)
        try:
            payload = await request.json()
        except ValueError:
            raise HTTPException(400, "Некорректный JSON")
        source_id = valid_id(payload.get("playlist_id") if isinstance(payload, dict) else None)
        async with httpx.AsyncClient(
                transport=httpx.ASGITransport(app=app),
                base_url=str(request.base_url),
                headers=client_headers(request),
                timeout=18) as client:
            library = await internal(client, "GET", "/api/playlists")
            own = library.get("playlists", []) if isinstance(library, dict) else []
            playlist = next((p for p in own if isinstance(p, dict)
                             and p.get("id") == source_id), None)
            if playlist is None:
                raise HTTPException(404, "Плейлист не найден в твоей библиотеке")
            response = await internal(client, "GET",
                                      "/api/playlists/" + quote(source_id, safe="") + "/tracks")
        entries = response.get("tracks", []) if isinstance(response, dict) else []
        if not isinstance(entries, list):
            raise HTTPException(502, "Неверный формат треков")
        safe = []
        seen = set()
        for item in entries:
            track = safe_track(item)
            if track and track["id"] not in seen:
                seen.add(track["id"])
                safe.append(track)
            if len(safe) > _MAX_TRACKS:
                raise HTTPException(413, "Максимум 500 треков для публикации")
        if not safe:
            raise HTTPException(400, "В плейлисте нет доступных для публикации треков")
        name = str(playlist.get("name") or "").strip()[:120]
        if not name:
            raise HTTPException(400, "Укажи название плейлиста")
        blob = " ".join([name] + [str(t.get("artist", "")) + " " + str(t.get("title", ""))
                                  for t in safe]).casefold()[:60000]
        now = time.time()
        with connect() as db:
            row = db.execute(
                "SELECT id, published_at FROM community_playlists "
                "WHERE owner=? AND source_playlist_id=?", (owner, source_id)).fetchone()
            if row:
                public_id, published = row["id"], row["published_at"]
            else:
                count = db.execute("SELECT COUNT(*) FROM community_playlists WHERE owner=?",
                                   (owner,)).fetchone()[0]
                if count >= 100:
                    raise HTTPException(429, "Можно опубликовать максимум 100 плейлистов")
                public_id, published = uuid.uuid4().hex, now
            db.execute(
                """INSERT INTO community_playlists
                   (id, owner, source_playlist_id, name, search_blob, cover_url,
                    tracks_json, track_count, published_at, updated_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                   ON CONFLICT(owner, source_playlist_id) DO UPDATE SET
                   name=excluded.name, search_blob=excluded.search_blob,
                   cover_url=excluded.cover_url, tracks_json=excluded.tracks_json,
                   track_count=excluded.track_count, updated_at=excluded.updated_at""",
                (public_id, owner, source_id, name, blob, safe[0].get("cover_url"),
                 json.dumps(safe, ensure_ascii=False), len(safe), published, now))
            db.commit()
        return {"id": public_id, "name": name, "published": True}

    @app.delete("/api/community-playlists/publish/{source_id}")
    async def unpublish_playlist(source_id: str, request: Request):
        owner = require_user(request)
        valid_id(source_id)
        with connect() as db:
            cur = db.execute(
                "DELETE FROM community_playlists WHERE owner=? AND source_playlist_id=?",
                (owner, source_id))
            db.commit()
        if not cur.rowcount:
            raise HTTPException(404, "Публикация не найдена")
        return {"ok": True}

    @app.get("/api/community-playlists/{public_id}")
    async def public_playlist(public_id: str):
        valid_id(public_id)
        with connect() as db:
            row = db.execute("SELECT * FROM community_playlists WHERE id=?",
                             (public_id,)).fetchone()
        if row is None:
            raise HTTPException(404, "Плейлист снят с публикации")
        return {"playlist": {**summary(row), "tracks": json.loads(row["tracks_json"])}}

    @app.post("/api/community-playlists/{public_id}/save")
    async def save_public_playlist(public_id: str, request: Request):
        require_user(request)
        valid_id(public_id)
        with connect() as db:
            row = db.execute("SELECT * FROM community_playlists WHERE id=?",
                             (public_id,)).fetchone()
        if row is None:
            raise HTTPException(404, "Плейлист снят с публикации")
        tracks = json.loads(row["tracks_json"])
        async with httpx.AsyncClient(
                transport=httpx.ASGITransport(app=app),
                base_url=str(request.base_url),
                headers=client_headers(request),
                timeout=25) as client:
            created = await internal(client, "POST", "/api/playlists",
                                     json={"name": row["name"][:120]})
            new_id = created.get("id") if isinstance(created, dict) else None
            if not isinstance(new_id, str) or not _ID.fullmatch(new_id):
                raise HTTPException(502, "Не удалось создать копию плейлиста")
            try:
                for track in tracks:
                    await internal(client, "POST",
                        "/api/playlists/" + quote(new_id, safe="") + "/tracks/" +
                        quote(track["id"], safe=""))
            except HTTPException:
                # Best effort cleanup. Never claim a partial copy was saved.
                try:
                    await client.delete("/api/playlists/" + quote(new_id, safe=""))
                except httpx.HTTPError:
                    pass
                raise
        return {"id": new_id, "name": row["name"]}
