"""Account-bound Nightwell Music device slots.

Install with install(app, core, premium_checker=...). The callable must return
True only for an ACTIVE paid subscription, not for an expired or pending one.
The original FastAPI app and its authenticated sessions table remain authoritative.
"""
from __future__ import annotations

import hashlib
import hmac
import os
import re
import sqlite3
import time
from pathlib import Path
from fastapi import HTTPException, Request
from fastapi.responses import JSONResponse
from starlette.concurrency import run_in_threadpool

DEVICE_ID = re.compile(r"^[a-z0-9][a-z0-9_-]{15,127}$")
ALLOWED_PLATFORM = {"ios", "android", "windows", "web"}
EXEMPT = {"/api/me", "/api/login", "/api/register", "/api/logout",
          "/api/auth/verify", "/api/auth/send-code"}
DEVICE_LIMIT_FREE = 2
DEVICE_LIMIT_PREMIUM = 5


class DeviceRegistry:
    def __init__(self, core, premium_checker, db_path):
        if not callable(premium_checker):
            raise ValueError("Provide a verified premium_checker(user_id) callback")
        self.core = core
        self.premium_checker = premium_checker
        self.path = str(Path(db_path).expanduser().resolve())
        Path(self.path).parent.mkdir(parents=True, exist_ok=True)
        with self.db() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS devices (
                    user_id TEXT NOT NULL,
                    device_id TEXT NOT NULL,
                    name TEXT NOT NULL,
                    platform TEXT NOT NULL,
                    created_at INTEGER NOT NULL,
                    last_seen INTEGER NOT NULL,
                    PRIMARY KEY(user_id, device_id)
                );
                CREATE TABLE IF NOT EXISTS device_sessions (
                    session_hash TEXT PRIMARY KEY,
                    user_id TEXT NOT NULL,
                    device_id TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS device_sessions_owner
                    ON device_sessions(user_id, device_id);
            """)

    def db(self):
        connection = sqlite3.connect(self.path, timeout=10)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA busy_timeout=10000")
        return connection

    def session(self, request):
        cookie = request.cookies.get("nw_session", "")
        if not cookie or len(cookie) > 512:
            raise HTTPException(401, "Войдите в аккаунт")
        token_hash = hashlib.sha256(cookie.encode()).hexdigest()
        with self.core.db() as db:
            row = db.execute(
                "SELECT user_id, csrf, expires FROM sessions WHERE token=?",
                (token_hash,)).fetchone()
        if not row or int(row["expires"]) <= int(time.time()):
            raise HTTPException(401, "Сеанс истёк. Войдите заново")
        return str(row["user_id"]), token_hash, str(row["csrf"])

    def limit(self, user_id):
        # Do not guess paid entitlements after a premium database failure.
        return DEVICE_LIMIT_PREMIUM if self.premium_checker(user_id) else DEVICE_LIMIT_FREE

    def summary(self, user_id, current_hash):
        limit = self.limit(user_id)
        with self.db() as db:
            owner = db.execute(
                "SELECT device_id FROM device_sessions WHERE session_hash=? AND user_id=?",
                (current_hash, user_id)).fetchone()
            current = owner["device_id"] if owner else ""
            rows = db.execute(
                "SELECT device_id, name, platform, created_at, last_seen FROM devices "
                "WHERE user_id=? ORDER BY created_at ASC, device_id ASC",
                (user_id,)).fetchall()
        devices = [dict(row) | {"current": row["device_id"] == current, "enabled": index < limit}
                   for index, row in enumerate(rows)]
        return {"devices": devices, "limit": limit, "count": len(devices),
                "premium": limit == DEVICE_LIMIT_PREMIUM}

    def register(self, user_id, current_hash, device_id, name, platform):
        if not isinstance(device_id, str) or not DEVICE_ID.fullmatch(device_id):
            raise HTTPException(400, "Некорректный идентификатор устройства")
        if not isinstance(name, str) or not isinstance(platform, str) or platform not in ALLOWED_PLATFORM:
            raise HTTPException(400, "Неизвестное устройство")
        name = name.strip()[:80]
        if not name:
            name = {"ios": "iPhone", "android": "Android", "windows": "Windows", "web": "Браузер"}[platform]
        limit = self.limit(user_id)
        now = int(time.time())
        with self.db() as db:
            db.execute("BEGIN IMMEDIATE")
            bound = db.execute(
                "SELECT device_id FROM device_sessions WHERE session_hash=?",
                (current_hash,)).fetchone()
            if bound and bound["device_id"] != device_id:
                raise HTTPException(403, "Эта сессия уже привязана к другому устройству")
            current = db.execute(
                "SELECT 1 FROM devices WHERE user_id=? AND device_id=?",
                (user_id, device_id)).fetchone()
            if not current:
                count = db.execute(
                    "SELECT COUNT(*) FROM devices WHERE user_id=?", (user_id,)).fetchone()[0]
                if count >= limit:
                    raise HTTPException(409, {
                        "code": "DEVICE_LIMIT_REACHED",
                        "error": f"Лимит устройств: {limit}. Удали старое устройство в профиле.",
                        "limit": limit
                    })
                db.execute(
                    "INSERT INTO devices VALUES(?,?,?,?,?,?)",
                    (user_id, device_id, name, platform, now, now))
            else:
                db.execute(
                    "UPDATE devices SET name=?, platform=?, last_seen=? "
                    "WHERE user_id=? AND device_id=?",
                    (name, platform, now, user_id, device_id))
            db.execute("INSERT OR REPLACE INTO device_sessions VALUES(?,?,?)",
                       (current_hash, user_id, device_id))
            db.commit()
        return self.summary(user_id, current_hash)

    def delete(self, user_id, device_id):
        with self.db() as db:
            db.execute("BEGIN IMMEDIATE")
            found = db.execute(
                "SELECT 1 FROM devices WHERE user_id=? AND device_id=?",
                (user_id, device_id)).fetchone()
            if not found:
                raise HTTPException(404, "Устройство не найдено")
            rows = db.execute(
                "SELECT session_hash FROM device_sessions WHERE user_id=? AND device_id=?",
                (user_id, device_id)).fetchall()
            # Kill the real authentication sessions, not only a local UI entry.
            with self.core.db() as auth:
                for row in rows:
                    auth.execute("DELETE FROM sessions WHERE token=? AND user_id=?",
                                 (row["session_hash"], user_id))
            db.execute("DELETE FROM device_sessions WHERE user_id=? AND device_id=?",
                       (user_id, device_id))
            db.execute("DELETE FROM devices WHERE user_id=? AND device_id=?",
                       (user_id, device_id))
            db.commit()

    def authorized(self, user_id, current_hash):
        limit = self.limit(user_id)
        with self.db() as db:
            device = db.execute(
                "SELECT device_id FROM device_sessions WHERE session_hash=? AND user_id=?",
                (current_hash, user_id)).fetchone()
            if not device:
                return "unregistered"
            active = db.execute(
                "SELECT device_id FROM devices WHERE user_id=? "
                "ORDER BY created_at ASC, device_id ASC LIMIT ?",
                (user_id, limit)).fetchall()
            return "ok" if any(row["device_id"] == device["device_id"] for row in active) else "overlimit"


def install(app, core, premium_checker, db_path="nightwell_devices.sqlite3"):
    """Register BEFORE serving requests. Fail closed if premium checking is missing."""
    if getattr(app.state, "nightwell_device_registry", None):
        return
    registry = DeviceRegistry(core, premium_checker, db_path)
    app.state.nightwell_device_registry = registry
    base = len(app.router.routes)

    def authorized(request, csrf=False):
        user_id, token_hash, expected_csrf = registry.session(request)
        if csrf and not hmac.compare_digest(request.headers.get("x-csrf-token", ""), expected_csrf):
            raise HTTPException(403, "Неверный CSRF-токен")
        return user_id, token_hash

    @app.get("/api/devices")
    async def devices(request: Request):
        user_id, token_hash = await run_in_threadpool(authorized, request)
        return await run_in_threadpool(registry.summary, user_id, token_hash)

    @app.post("/api/devices/register")
    async def register_device(request: Request):
        user_id, token_hash = await run_in_threadpool(authorized, request, True)
        body = await request.json()
        if not isinstance(body, dict):
            raise HTTPException(400, "Некорректный JSON")
        return await run_in_threadpool(
            registry.register, user_id, token_hash,
            body.get("device_id"), body.get("name"), body.get("platform"))

    @app.delete("/api/devices/{device_id}")
    async def revoke_device(request: Request, device_id: str):
        user_id, token_hash = await run_in_threadpool(authorized, request, True)
        await run_in_threadpool(registry.delete, user_id, device_id)
        return {"ok": True}

    # Avoid a legacy catch-all /api/{path} intercepting the new endpoints.
    app.router.routes[:] = app.router.routes[base:] + app.router.routes[:base]

    @app.middleware("http")
    async def require_registered_device(request: Request, call_next):
        path = request.url.path
        if not path.startswith("/api/") or path in EXEMPT or path.startswith("/api/devices") or path.startswith("/api/premium/"):
            return await call_next(request)
        cookie = request.cookies.get("nw_session", "")
        if not cookie:
            return await call_next(request)
        try:
            user_id, token_hash, _ = await run_in_threadpool(registry.session, request)
            status = await run_in_threadpool(registry.authorized, user_id, token_hash)
        except HTTPException as error:
            return JSONResponse({"error": str(error.detail)}, status_code=error.status_code)
        except Exception:
            return JSONResponse({"error": "Не удалось проверить привязку устройства"}, status_code=503)
        if status == "unregistered":
            return JSONResponse({"error": "Зарегистрируй устройство в аккаунте",
                                 "code": "DEVICE_REGISTRATION_REQUIRED"}, status_code=428)
        if status == "overlimit":
            return JSONResponse({"error": "Лимит устройств после окончания Premium. Отключи лишние устройства.",
                                 "code": "DEVICE_LIMIT_REACHED"}, status_code=403)
        return await call_next(request)
