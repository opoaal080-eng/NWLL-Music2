"""Account-synced artist preferences and low-latency personalised Nightwell wave.

Mount with install(app, identity, db_path) after the original /api/wave endpoint.
The existing wave remains the fallback. This module never stores audio files.
"""
import asyncio
import hashlib
import json
import re
import sqlite3
import time
import unicodedata
from collections import Counter
from contextlib import contextmanager
from pathlib import Path

import httpx
from fastapi import HTTPException, Request

MAX_ARTISTS = 20
SAFE_HEADERS = {"cookie", "authorization", "origin", "x-csrf-token"}
SPLIT_ARTISTS = re.compile(r"\s*(?:,|;|\bfeat\.?\b|\bft\.?\b|\s+[&×]\s+|\s+и\s+)\s*", re.IGNORECASE)


def artist_key(text):
    normalized = unicodedata.normalize("NFKD", text.casefold().replace("ё", "е"))
    return "".join(c for c in normalized if c.isalnum())


def valid_artist(name):
    return isinstance(name, str) and 2 <= len(name.strip()) <= 90 and not any(
        ord(char) < 32 for char in name)


def matches_artist(value, preferred):
    return any(artist_key(part) in preferred
               for part in SPLIT_ARTISTS.split(str(value or "")) if artist_key(part))


def install(app, identity, db_path):
    target = Path(db_path).resolve()
    target.parent.mkdir(parents=True, exist_ok=True)

    @contextmanager
    def db():
        conn = sqlite3.connect(str(target), timeout=10)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA busy_timeout=10000")
        try:
            with conn:
                yield conn
        finally:
            conn.close()

    with db() as conn:
        conn.execute("""CREATE TABLE IF NOT EXISTS wave_favourite_artists (
            owner TEXT PRIMARY KEY,
            artists_json TEXT NOT NULL,
            updated REAL NOT NULL)""")

    def user(request):
        owner = identity(request)
        if not owner:
            raise HTTPException(401, "Войди в Nightwell Music")
        return str(owner)

    def get_saved(owner):
        with db() as conn:
            row = conn.execute(
                "SELECT artists_json FROM wave_favourite_artists WHERE owner=?",
                (owner,)).fetchone()
        if row is None:
            return [], False
        try:
            return json.loads(row["artists_json"]), True
        except (ValueError, TypeError):
            return [], False

    def headers(request):
        return {k: v for k, v in request.headers.items() if k.lower() in SAFE_HEADERS}

    @app.get("/api/wave-artists/preferences")
    async def read_preferences(request: Request):
        artists, configured = get_saved(user(request))
        return {"artists": artists, "configured": configured, "max_artists": MAX_ARTISTS}

    @app.put("/api/wave-artists/preferences")
    async def write_preferences(request: Request):
        owner = user(request)
        try:
            payload = await request.json()
        except ValueError:
            raise HTTPException(400, "Неверный формат запроса")
        entries = payload.get("artists") if isinstance(payload, dict) else None
        if not isinstance(entries, list) or len(entries) > MAX_ARTISTS:
            raise HTTPException(400, "Выбери не больше 20 исполнителей")
        cleaned, seen = [], set()
        for artist in entries:
            if not valid_artist(artist):
                raise HTTPException(400, "Недопустимое имя исполнителя")
            name = " ".join(artist.strip().split())
            key = artist_key(name)
            if not key:
                raise HTTPException(400, "Недопустимое имя исполнителя")
            if key not in seen:
                seen.add(key)
                cleaned.append(name)
        with db() as conn:
            conn.execute(
                """INSERT INTO wave_favourite_artists(owner, artists_json, updated)
                VALUES(?,?,?)
                ON CONFLICT(owner) DO UPDATE SET
                  artists_json=excluded.artists_json, updated=excluded.updated""",
                (owner, json.dumps(cleaned, ensure_ascii=False), time.time()))
        return {"artists": cleaned, "configured": True, "max_artists": MAX_ARTISTS}

    @app.get("/api/wave-artists/suggestions")
    async def suggestions(request: Request, q: str = "", limit: int = 24):
        user(request)
        text = q.strip()[:90]
        limit = max(1, min(40, limit))
        async with httpx.AsyncClient(
                transport=httpx.ASGITransport(app=app),
                base_url=str(request.base_url),
                headers=headers(request), timeout=12) as client:
            response = await client.get("/api/tracks")
        if response.status_code != 200:
            raise HTTPException(503, "Каталог исполнителей пока недоступен")
        try:
            tracks = response.json().get("tracks", [])
        except (ValueError, AttributeError):
            tracks = []
        if not isinstance(tracks, list):
            tracks = []
        counts, display = Counter(), {}
        query = artist_key(text)
        for track in tracks[:10000]:
            if not isinstance(track, dict):
                continue
            artist = track.get("artist")
            if not isinstance(artist, str):
                continue
            for name in SPLIT_ARTISTS.split(artist):
                name = " ".join(name.split())[:90]
                key = artist_key(name)
                if not key or len(name) < 2 or (query and query not in key):
                    continue
                counts[key] += 1
                display.setdefault(key, name)
        ranked = sorted(counts.items(), key=lambda pair: (-pair[1], pair[0]))[:limit]
        return {"artists": [{"name": display[key], "track_count": count}
                            for key, count in ranked]}

    @app.get("/api/wave-artists/mix")
    async def personalized_mix(request: Request):
        owner = user(request)
        artists, _ = get_saved(owner)
        params = {key: value for key, value in request.query_params.items()
                  if key in {"mix", "exclude", "character", "mood", "language"}}
        async with httpx.AsyncClient(
                transport=httpx.ASGITransport(app=app),
                base_url=str(request.base_url),
                headers=headers(request), timeout=22) as client:
            original = await client.get("/api/wave", params=params)
            if original.status_code != 200:
                raise HTTPException(original.status_code, "Не удалось получить подборку")
            try:
                payload = original.json()
            except ValueError:
                raise HTTPException(502, "Некорректная подборка")
            if not isinstance(payload, dict):
                raise HTTPException(502, "Некорректная подборка")
            base = payload.get("tracks", [])
            if not isinstance(base, list):
                base = []
            if not artists:
                payload["tracks"] = base
                return payload

            preferred = {artist_key(x) for x in artists}
            excluded = set(params.get("exclude", "").split(","))
            items, seen = [], set()

            def push(track):
                if not isinstance(track, dict):
                    return
                identifier = track.get("id")
                if not isinstance(identifier, str) or not identifier or identifier in seen or identifier in excluded:
                    return
                if not isinstance(track.get("title"), str) or not isinstance(track.get("artist"), str):
                    return
                seen.add(identifier)
                items.append(track)

            for item in base:
                push(item)

            # Two concurrent optional lookups (1.3s budget) introduce a few
            # preferred tracks when the ordinary wave happens to miss them.
            # They never block or replace the ordinary wave on timeout/errors.
            choice = artists[:]
            offset = int.from_bytes(hashlib.sha256(
                (owner + params.get("mix", "")).encode()).digest()[:2], "big")
            if choice:
                choice = choice[offset % len(choice):] + choice[:offset % len(choice)]
            async def lookup(name):
                try:
                    response = await client.get("/api/tracks", params={"q": name}, timeout=1.25)
                    if response.status_code != 200:
                        return []
                    result = response.json()
                    return result.get("tracks", []) if isinstance(result, dict) else []
                except (httpx.HTTPError, ValueError):
                    return []
            searches = await asyncio.gather(*(lookup(name) for name in choice[:2]))
            for group in searches:
                for item in group[:45]:
                    if matches_artist(item.get("artist") if isinstance(item, dict) else "", preferred):
                        push(item)

            favorites = [item for item in items if matches_artist(item.get("artist"), preferred)]
            others = [item for item in items if not matches_artist(item.get("artist"), preferred)]
            result = []
            # Roughly 1 favourite every 2 other tracks, preserving discoverability.
            while favorites or others:
                if favorites:
                    result.append(favorites.pop(0))
                for _ in range(2):
                    if others:
                        result.append(others.pop(0))
                if not favorites and not others:
                    break
            payload["tracks"] = result[:max(1, len(base), 40)]
            payload["artist_preferences_applied"] = bool(favorites or result)
            return payload
