"""Account-scoped Nightwell device registry for a compatible FastAPI server.

Install AFTER existing authentication routes:
    from account_devices import install
    install(app, identity, "data/account_devices.sqlite3")

The existing /api/me (CSRF) and /api/premium/me (subscription) are consulted
in-process. Native clients send X-NW-Device-ID and X-NW-Device-Platform.
Legacy clients without the new header continue working during rollout.
"""
import inspect
import re
import secrets
import sqlite3
import time
from pathlib import Path

from fastapi import HTTPException, Request
from fastapi.responses import JSONResponse

DEVICE_PATTERN = re.compile(r"^(?:ios_|android_|windows-)[A-Za-z0-9_-]{12,100}$")
PLATFORMS = {"ios", "android", "windows"}
EXEMPT_ROUTES = frozenset({
    "/api/me", "/api/login", "/api/register", "/api/logout",
    "/api/premium/me",
})


def install(app, identity, db_path, premium_for_account=None):
    """Use the host app's authenticated identity, not a client-supplied owner."""
    if getattr(app.state, "nw_device_registry_installed", False):
        return
    app.state.nw_device_registry_installed = True
    database = Path(db_path)
    database.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(database, timeout=15) as db:
        db.execute("""CREATE TABLE IF NOT EXISTS nw_account_devices (
            owner TEXT NOT NULL, id TEXT NOT NULL, name TEXT NOT NULL,
            platform TEXT NOT NULL, created REAL NOT NULL,
            last_seen REAL NOT NULL, PRIMARY KEY(owner, id))""")
        db.execute("CREATE INDEX IF NOT EXISTS nw_devices_owner_seen ON nw_account_devices(owner,last_seen DESC)")

    async def owner_for(request):
        try:
            owner = identity(request)
            if inspect.isawaitable(owner):
                owner = await owner
            if isinstance(owner, dict):
                owner = owner.get("user_id") or owner.get("id")
            return str(owner) if owner else None
        except HTTPException:
            return None

    async def internal_api(request, path):
        import httpx
        headers = {"cookie": request.headers.get("cookie", "")}
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app),
                                     base_url="http://nightwell.internal",
                                     headers=headers, timeout=8) as client:
            result = await client.get(path)
        if result.status_code != 200:
            return {}
        try:
            return result.json()
        except (ValueError, TypeError):
            return {}

    async def require_csrf(request):
        sent = request.headers.get("x-csrf-token", "")
        profile = await internal_api(request, "/api/me")
        expected = profile.get("csrf")
        if not isinstance(expected, str) or not sent or not secrets.compare_digest(expected, sent):
            raise HTTPException(403, "Недействительный токен защиты сессии")

    async def premium_for(request, owner):
        if premium_for_account is not None:
            try:
                value = premium_for_account(owner)
                if inspect.isawaitable(value):
                    value = await value
                return bool(value)
            except Exception:
                return False
        try:
            result = await internal_api(request, "/api/premium/me")
            if not result.get("premium"):
                return False
            expires = result.get("expires_at")
            return expires is None or float(expires) > time.time()
        except (TypeError, ValueError, OSError):
            return False

    def connect():
        db = sqlite3.connect(database, timeout=15, isolation_level=None)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA busy_timeout=15000")
        return db

    def ordered(db, owner):
        return db.execute(
            "SELECT * FROM nw_account_devices WHERE owner=? ORDER BY last_seen DESC,created DESC,id",
            (owner,)).fetchall()

    def denied(limit):
        return JSONResponse(status_code=409, content={
            "error": "Достигнут лимит устройств. Удали старое устройство в профиле.",
            "code": "device_limit", "limit": limit,
        })

    def verify_existing(owner, device_id, limit):
        with connect() as db:
            rows = ordered(db, owner)
            permitted = {row["id"] for row in rows[:limit]}
            if device_id not in permitted:
                return False
            db.execute(
                "UPDATE nw_account_devices SET last_seen=? WHERE owner=? AND id=? AND last_seen<?",
                (time.time(), owner, device_id, time.time() - 60))
        return True

    @app.middleware("http")
    async def restrict_native_devices(request, call_next):
        path = request.url.path
        platform = request.headers.get("x-nw-device-platform", "").lower()
        if (not path.startswith("/api/") or path.startswith("/api/devices") or
                path in EXEMPT_ROUTES or platform not in PLATFORMS):
            return await call_next(request)
        owner = await owner_for(request)
        if owner is None:
            return await call_next(request)
        device_id = request.headers.get("x-nw-device-id", "")
        if not DEVICE_PATTERN.fullmatch(device_id):
            return JSONResponse(status_code=400, content={
                "error": "Необходимо зарегистрировать устройство", "code": "device_required"})
        limit = 5 if await premium_for(request, owner) else 2
        if not verify_existing(owner, device_id, limit):
            return denied(limit)
        return await call_next(request)

    @app.get("/api/devices")
    async def devices(request: Request):
        owner = await owner_for(request)
        if owner is None:
            raise HTTPException(401, "Войди в аккаунт")
        premium = await premium_for(request, owner)
        limit = 5 if premium else 2
        current = request.headers.get("x-nw-device-id", "")
        with connect() as db:
            rows = ordered(db, owner)
        return {
            "limit": limit, "count": len(rows), "premium": premium,
            "devices": [{
                "id": row["id"], "name": row["name"], "platform": row["platform"],
                "created_at": row["created"], "last_seen": row["last_seen"],
                "current": row["id"] == current, "blocked": index >= limit,
            } for index, row in enumerate(rows)],
        }

    @app.post("/api/devices/register")
    async def register(request: Request):
        owner = await owner_for(request)
        if owner is None:
            raise HTTPException(401, "Войди в аккаунт")
        await require_csrf(request)
        try:
            body = await request.json()
        except (ValueError, TypeError):
            raise HTTPException(400, "Некорректные сведения об устройстве")
        if not isinstance(body, dict):
            raise HTTPException(400, "Некорректные сведения об устройстве")
        device_id = body.get("device_id")
        platform = body.get("platform")
        if device_id != request.headers.get("x-nw-device-id"):
            raise HTTPException(400, "Несовпадающий идентификатор устройства")
        if not isinstance(device_id, str) or not DEVICE_PATTERN.fullmatch(device_id) or platform not in PLATFORMS:
            raise HTTPException(400, "Недопустимое устройство")
        if platform != request.headers.get("x-nw-device-platform", "").lower():
            raise HTTPException(400, "Некорректная платформа")
        name = body.get("name") or platform.upper()
        if not isinstance(name, str) or not name.strip():
            name = platform.upper()
        name = name.strip()[:80]
        limit = 5 if await premium_for(request, owner) else 2
        now = time.time()
        with connect() as db:
            db.execute("BEGIN IMMEDIATE")
            rows = ordered(db, owner)
            ids = [row["id"] for row in rows]
            if device_id in ids:
                if ids.index(device_id) >= limit:
                    db.execute("ROLLBACK")
                    return denied(limit)
                db.execute("""UPDATE nw_account_devices SET name=?,platform=?,last_seen=?
                              WHERE owner=? AND id=?""",
                           (name, platform, now, owner, device_id))
            else:
                if len(ids) >= limit:
                    db.execute("ROLLBACK")
                    return denied(limit)
                db.execute("""INSERT INTO nw_account_devices(owner,id,name,platform,created,last_seen)
                              VALUES(?,?,?,?,?,?)""",
                           (owner, device_id, name, platform, now, now))
            db.execute("COMMIT")
        return {"ok": True, "limit": limit, "device_id": device_id}

    @app.delete("/api/devices/{device_id}")
    async def remove_device(device_id: str, request: Request):
        owner = await owner_for(request)
        if owner is None:
            raise HTTPException(401, "Войди в аккаунт")
        await require_csrf(request)
        if not DEVICE_PATTERN.fullmatch(device_id):
            raise HTTPException(400, "Неверный идентификатор")
        with connect() as db:
            db.execute("BEGIN IMMEDIATE")
            cursor = db.execute("DELETE FROM nw_account_devices WHERE owner=? AND id=?",
                                (owner, device_id))
            db.execute("COMMIT")
        if not cursor.rowcount:
            raise HTTPException(404, "Устройство не найдено")
        return {"ok": True}
