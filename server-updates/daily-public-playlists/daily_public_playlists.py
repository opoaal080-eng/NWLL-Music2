"""Daily per-account public-catalog playlists for Nightwell Music.

Mount with: from daily_public_playlists import install
            install(app, identity, db_path)
Only catalog metadata is used; users' private libraries are never published.
"""
import datetime
import hashlib
import json
import random
import sqlite3
import time
from contextlib import contextmanager

from fastapi import HTTPException, Request

COLLECTIONS = (
    ("daily-mix", "Твой дневной микс", 30),
    ("discover", "Открой новое", 30),
    ("night", "Ночной ритм", 30),
)


def install(app, identity, db_path):
    @contextmanager
    def db():
        conn = sqlite3.connect(str(db_path), timeout=10)
        try:
            with conn:
                conn.execute("""CREATE TABLE IF NOT EXISTS daily_public_playlists (
                    account TEXT NOT NULL, day TEXT NOT NULL,
                    payload TEXT NOT NULL, updated REAL NOT NULL,
                    PRIMARY KEY (account,day))""")
                yield conn
        finally:
            conn.close()

    def logged_in(request):
        account = identity(request)
        if not account:
            raise HTTPException(401, "Войди в Nightwell Music")
        return str(account)

    @app.get("/api/daily-public-playlists")
    async def daily_public_playlists(request: Request):
        account = logged_in(request)
        today = datetime.datetime.now(datetime.timezone.utc).date().isoformat()
        with db() as conn:
            saved = conn.execute("SELECT payload FROM daily_public_playlists WHERE account=? AND day=?",
                                 (account, today)).fetchone()
            if saved:
                return json.loads(saved[0])

        # Internal catalog endpoint uses the existing account session.
        import httpx
        headers = {k: v for k, v in request.headers.items()
                   if k.lower() in ("cookie", "x-csrf-token", "origin")}
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app),
                                     base_url=str(request.base_url), headers=headers,
                                     timeout=20) as client:
            response = await client.get("/api/tracks")
            if response.status_code != 200:
                raise HTTPException(503, "Каталог временно недоступен")
            catalog = response.json().get("tracks", [])
        if not isinstance(catalog, list):
            raise HTTPException(503, "Не удалось получить каталог")

        safe = []
        ids = set()
        for item in catalog:
            if not isinstance(item, dict):
                continue
            track_id = item.get("id", "")
            if not isinstance(track_id, str) or not track_id or track_id in ids:
                continue
            if not item.get("title") or not item.get("artist"):
                continue
            ids.add(track_id)
            safe.append(item)

        # Stable account-specific selection; changes once a day (00:00 UTC).
        # No personal listening history is exposed to other accounts.
        playlists = []
        for code, name, limit in COLLECTIONS:
            digest = hashlib.sha256((account + "|" + today + "|" + code).encode()).digest()
            rng = random.Random(int.from_bytes(digest, "big"))
            choice = safe[:]
            rng.shuffle(choice)
            playlists.append({"id": code, "name": name, "tracks": choice[:limit],
                              "count": min(len(choice), limit)})
        result = {"date": today, "playlists": playlists}
        with db() as conn:
            # Concurrent requests for the same account/day should receive the same result.
            conn.execute("INSERT OR IGNORE INTO daily_public_playlists VALUES (?,?,?,?)",
                         (account, today, json.dumps(result, ensure_ascii=False), time.time()))
            saved = conn.execute("SELECT payload FROM daily_public_playlists WHERE account=? AND day=?",
                                 (account, today)).fetchone()
            conn.execute("DELETE FROM daily_public_playlists WHERE updated<?", (time.time()-14*86400,))
        return json.loads(saved[0])
