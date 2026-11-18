"""Nightwell Music private now-playing feed for iOS WidgetKit (FastAPI).

The widget has NO login cookie and uses its own revocable bearer token.
A short-lived, single-use pairing code is created by a signed-in user.
Only track display metadata and a small JPEG are exposed. Never expose
session cookies, playlist contents, email or payment information.
"""
import base64
import binascii
import hashlib
import inspect
import re
import secrets
import sqlite3
import time
from pathlib import Path

from fastapi import HTTPException, Request
from fastapi.responses import Response, JSONResponse

CODE_RE = re.compile(r"^[A-F0-9]{16}$")
TRACK_RE = re.compile(r"^[^\x00-\x1f\x7f]{0,100}$")
TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{36,90}$")
PAIR_TTL = 600
NO_STORE = {"Cache-Control": "private, no-store, max-age=0", "Pragma": "no-cache"}


def digest(value):
    return hashlib.sha256(value.encode("ascii")).hexdigest()


def install(app, identity, db_path, csrf_verifier):
    """Attach routes once. identity(request) and csrf_verifier(request) are host callbacks."""
    if getattr(app.state, "nw_widget_sync_installed", False):
        return
    if not callable(identity) or not callable(csrf_verifier):
        raise ValueError("Нужны действующие identity(request) и csrf_verifier(request)")
    database = Path(db_path)
    database.parent.mkdir(parents=True, exist_ok=True)

    def connect():
        db = sqlite3.connect(database, timeout=15)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA busy_timeout=15000")
        return db

    with connect() as db:
        db.execute("""CREATE TABLE IF NOT EXISTS nw_widget_pairs (
            digest TEXT PRIMARY KEY, owner TEXT NOT NULL, expires REAL NOT NULL)""")
        db.execute("CREATE INDEX IF NOT EXISTS nw_widget_pairs_owner ON nw_widget_pairs(owner)")
        db.execute("""CREATE TABLE IF NOT EXISTS nw_widget_tokens (
            digest TEXT PRIMARY KEY, owner TEXT NOT NULL, created REAL NOT NULL)""")
        db.execute("CREATE INDEX IF NOT EXISTS nw_widget_tokens_owner ON nw_widget_tokens(owner)")
        db.execute("""CREATE TABLE IF NOT EXISTS nw_widget_state (
            owner TEXT PRIMARY KEY, track_id TEXT NOT NULL DEFAULT '',
            title TEXT NOT NULL DEFAULT '', artist TEXT NOT NULL DEFAULT '',
            playing INTEGER NOT NULL DEFAULT 0, cover BLOB, updated REAL NOT NULL)""")
        # Reverse pairing: the widget owns a private random token. The
        # displayed short-lived code is only a challenge, never a bearer key.
        db.execute("""CREATE TABLE IF NOT EXISTS nw_widget_device_pairs (
            token_digest TEXT PRIMARY KEY, code TEXT UNIQUE NOT NULL,
            expires REAL NOT NULL)""")
    app.state.nw_widget_sync_installed = True

    async def owner_for(request):
        try:
            who = identity(request)
            if inspect.isawaitable(who):
                who = await who
            if isinstance(who, dict):
                who = who.get("user_id") or who.get("id")
            if not who:
                raise HTTPException(401, "Войди в Nightwell Music")
            return str(who)
        except HTTPException:
            raise

    async def csrf_for(request):
        check = csrf_verifier(request)
        if inspect.isawaitable(check):
            check = await check
        if not check:
            raise HTTPException(403, "Недействительная защита сессии")

    async def body_for(request):
        try:
            raw = await request.body()
            if len(raw) > 360_000:
                raise HTTPException(413, "Слишком большой запрос")
            import json
            result = json.loads(raw)
            if not isinstance(result, dict):
                raise ValueError("expected object")
            return result
        except (TypeError, ValueError, UnicodeError):
            raise HTTPException(400, "Неверный формат запроса")

    def checked_text(obj, key, max_length):
        value = obj.get(key, "")
        if not isinstance(value, str) or len(value) > max_length:
            raise HTTPException(400, "Недопустимое поле: " + key)
        return value

    def bearer_owner(request):
        # A widget credential is NOT an account JWT. The host's global auth
        # middleware may reject arbitrary Authorization: Bearer values before
        # FastAPI gets to this route. Use a dedicated header for widget calls,
        # preserving support for existing clients that send Bearer.
        token = request.headers.get("x-nightwell-widget-token", "")
        if not token:
            raw = request.headers.get("authorization", "")
            token = raw[7:] if raw.startswith("Bearer ") else ""
        if not TOKEN_RE.fullmatch(token):
            raise HTTPException(401, "Подключи виджет заново")
        with connect() as db:
            row = db.execute("SELECT owner FROM nw_widget_tokens WHERE digest=?",
                             (digest(token),)).fetchone()
        if not row:
            raise HTTPException(401, "Привязка виджета недействительна")
        return row["owner"]

    @app.post("/api/widgets/pair-code")
    async def widget_pair_code(request: Request):
        owner = await owner_for(request)
        await csrf_for(request)
        code = secrets.token_hex(8).upper()  # 64 bits, 10-minute lifespan
        now = time.time()
        with connect() as db:
            db.execute("DELETE FROM nw_widget_pairs WHERE expires<? OR owner=?", (now, owner))
            db.execute("INSERT INTO nw_widget_pairs VALUES (?,?,?)",
                       (digest(code), owner, now + PAIR_TTL))
        return JSONResponse({"code": "-".join(code[n:n + 4] for n in range(0, 16, 4)),
                             "expires_in": PAIR_TTL}, headers=NO_STORE)

    @app.post("/api/widgets/pair")
    async def widget_pair(request: Request):
        body = await body_for(request)
        code = str(body.get("code", "")).replace("-", "").strip().upper()
        if not CODE_RE.fullmatch(code):
            raise HTTPException(400, "Неверный код виджета")
        now = time.time()
        token = secrets.token_urlsafe(32)
        with connect() as db:
            db.execute("BEGIN IMMEDIATE")
            found = db.execute("SELECT owner FROM nw_widget_pairs WHERE digest=? AND expires>?",
                               (digest(code), now)).fetchone()
            if not found:
                raise HTTPException(401, "Код истёк или уже использован")
            owner = found["owner"]
            db.execute("DELETE FROM nw_widget_pairs WHERE digest=?", (digest(code),))
            # Limit how many long-lived tokens can remain active per account.
            old = db.execute("SELECT digest FROM nw_widget_tokens WHERE owner=? ORDER BY created DESC",
                             (owner,)).fetchall()
            for row in old[9:]:
                db.execute("DELETE FROM nw_widget_tokens WHERE digest=?", (row["digest"],))
            db.execute("INSERT INTO nw_widget_tokens VALUES (?,?,?)",
                       (digest(token), owner, now))
        return JSONResponse({"token": token}, headers=NO_STORE)

    @app.get("/api/widgets/device/health")
    async def widget_device_health(request: Request):
        # Deliberately public and metadata-only. A 401 here means an outer
        # auth middleware or proxy is intercepting the widget endpoints.
        return JSONResponse({"widget_sync": "v3.1", "ready": True}, headers=NO_STORE)

    @app.post("/api/widgets/device/register")
    async def widget_device_register(request: Request):
        token = request.headers.get("x-nightwell-widget-token", "")
        if not token:
            # Keep V3 backward compatibility for already installed widgets.
            raw = request.headers.get("authorization", "")
            token = raw[7:] if raw.startswith("Bearer ") else ""
        if not re.fullmatch(r"[A-Za-z0-9_-]{43}", token):
            raise HTTPException(400, "Некорректный ключ устройства")
        token_digest = digest(token)
        now = time.time()
        with connect() as db:
            db.execute("BEGIN IMMEDIATE")
            if db.execute("SELECT 1 FROM nw_widget_tokens WHERE digest=?",
                          (token_digest,)).fetchone():
                return JSONResponse({"paired": True}, headers=NO_STORE)
            db.execute("DELETE FROM nw_widget_device_pairs WHERE expires<=?", (now,))
            row = db.execute("SELECT code, expires FROM nw_widget_device_pairs WHERE token_digest=?",
                             (token_digest,)).fetchone()
            if row:
                code = row["code"]
                expires = row["expires"]
            else:
                count = db.execute("SELECT COUNT(*) FROM nw_widget_device_pairs").fetchone()[0]
                if count >= 4096:
                    raise HTTPException(429, "Слишком много подключений. Повтори позже.")
                code = secrets.token_hex(8).upper()
                expires = now + 900
                db.execute("INSERT INTO nw_widget_device_pairs VALUES (?,?,?)",
                           (token_digest, code, expires))
        return JSONResponse({"paired": False,
            "code": "-".join(code[n:n+4] for n in range(0,16,4)),
            "expires_in": int(expires - now)}, headers=NO_STORE)

    @app.post("/api/widgets/device/claim")
    async def widget_device_claim(request: Request):
        owner = await owner_for(request)
        await csrf_for(request)
        body = await body_for(request)
        code = str(body.get("code", "")).replace("-", "").strip().upper()
        if not CODE_RE.fullmatch(code):
            raise HTTPException(400, "Нужен код из самого виджета")
        now = time.time()
        with connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT token_digest FROM nw_widget_device_pairs WHERE code=? AND expires>?",
                             (code, now)).fetchone()
            if not row:
                raise HTTPException(401, "Код истёк или уже использован")
            token_digest = row["token_digest"]
            if db.execute("SELECT 1 FROM nw_widget_tokens WHERE digest=?", (token_digest,)).fetchone():
                raise HTTPException(409, "Виджет уже подключён")
            old = db.execute("SELECT digest FROM nw_widget_tokens WHERE owner=? ORDER BY created DESC",
                             (owner,)).fetchall()
            for item in old[9:]:
                db.execute("DELETE FROM nw_widget_tokens WHERE digest=?", (item["digest"],))
            db.execute("INSERT INTO nw_widget_tokens VALUES (?,?,?)", (token_digest, owner, now))
            db.execute("DELETE FROM nw_widget_device_pairs WHERE token_digest=?", (token_digest,))
        return JSONResponse({"ok": True}, headers=NO_STORE)

    @app.post("/api/widgets/state")
    async def widget_save_state(request: Request):
        owner = await owner_for(request)
        await csrf_for(request)
        body = await body_for(request)
        track_id = checked_text(body, "track_id", 100)
        if not TRACK_RE.fullmatch(track_id):
            raise HTTPException(400, "Недопустимый трек")
        title = checked_text(body, "title", 180) if track_id else ""
        artist = checked_text(body, "artist", 180) if track_id else ""
        playing = bool(body.get("playing") is True and track_id)
        now = time.time()
        with connect() as db:
            # Preserve only artwork belonging to the SAME track.
            db.execute("""INSERT INTO nw_widget_state
                (owner, track_id, title, artist, playing, cover, updated)
                VALUES (?,?,?,?,?,NULL,?)
                ON CONFLICT(owner) DO UPDATE SET
                cover = CASE WHEN nw_widget_state.track_id=excluded.track_id
                             THEN nw_widget_state.cover ELSE NULL END,
                track_id=excluded.track_id, title=excluded.title,
                artist=excluded.artist, playing=excluded.playing, updated=excluded.updated""",
                (owner, track_id, title, artist, int(playing), now))
        return {"ok": True}

    @app.post("/api/widgets/cover")
    async def widget_save_cover(request: Request):
        owner = await owner_for(request)
        await csrf_for(request)
        body = await body_for(request)
        track_id = checked_text(body, "track_id", 100)
        encoded = checked_text(body, "jpeg", 300_000)
        try:
            data = base64.b64decode(encoded, validate=True)
        except (ValueError, binascii.Error):
            raise HTTPException(400, "Неверное изображение")
        if not 100 <= len(data) <= 220_000 or not data.startswith(b"\xff\xd8\xff"):
            raise HTTPException(400, "Изображение должно быть JPEG до 220 КБ")
        with connect() as db:
            cursor = db.execute(
                "UPDATE nw_widget_state SET cover=?, updated=? WHERE owner=? AND track_id=? AND track_id!=''",
                (data, time.time(), owner, track_id))
            if not cursor.rowcount:
                raise HTTPException(409, "Сейчас воспроизводится другой трек")
        return {"ok": True}

    @app.get("/api/widgets/state")
    async def widget_public_state(request: Request):
        owner = bearer_owner(request)
        with connect() as db:
            row = db.execute("SELECT * FROM nw_widget_state WHERE owner=?", (owner,)).fetchone()
        if not row:
            data = {"track_id": "", "title": "Твой ритм",
                    "artist": "Nightwell Music", "playing": False,
                    "has_cover": False, "updated_at": 0}
        else:
            data = {"track_id": row["track_id"], "title": row["title"] or "Твой ритм",
                    "artist": row["artist"] or "Nightwell Music", "playing": bool(row["playing"]),
                    "has_cover": row["cover"] is not None, "updated_at": row["updated"]}
        return JSONResponse(data, headers=NO_STORE)

    @app.get("/api/widgets/cover")
    async def widget_public_cover(request: Request):
        owner = bearer_owner(request)
        with connect() as db:
            row = db.execute("SELECT cover FROM nw_widget_state WHERE owner=?", (owner,)).fetchone()
        if not row or row["cover"] is None:
            raise HTTPException(404, "Обложка пока не загружена")
        return Response(content=row["cover"], media_type="image/jpeg", headers=NO_STORE)

    @app.post("/api/widgets/revoke-all")
    async def widget_revoke_all(request: Request):
        owner = await owner_for(request)
        await csrf_for(request)
        with connect() as db:
            db.execute("DELETE FROM nw_widget_pairs WHERE owner=?", (owner,))
            db.execute("DELETE FROM nw_widget_tokens WHERE owner=?", (owner,))
        return {"ok": True}
