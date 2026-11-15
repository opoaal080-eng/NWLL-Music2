"""Account-scoped logical devices with secret credentials and session revocation."""
import hashlib
import re
import secrets
import time

from access_database import AccessError

DEVICE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{11,127}$")
PLATFORMS = frozenset({"ios", "android", "windows", "web"})


def session_digest(account_id, session_key):
    if not isinstance(session_key, str) or not session_key or len(session_key) > 8192:
        raise AccessError(503, "session_adapter_required", "Сервер не определил сессию аккаунта.")
    return hashlib.sha256(("nw-session-v1\0" + account_id + "\0" + session_key).encode()).hexdigest()


def credential_digest(token):
    if not isinstance(token, str) or not 32 <= len(token) <= 128:
        raise AccessError(401, "device_required", "Подтвердите устройство или войдите снова.")
    return hashlib.sha256(("nw-device-v1\0" + token).encode()).hexdigest()


class DeviceService:
    def __init__(self, database, clock=time.time):
        self.database, self.clock = database, clock
        with database.transaction() as db:
            db.execute("""CREATE TABLE IF NOT EXISTS nw_access_devices (
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                account_id TEXT NOT NULL, id TEXT NOT NULL,
                token_hash TEXT NOT NULL UNIQUE, name TEXT NOT NULL,
                platform TEXT NOT NULL, created_at REAL NOT NULL, last_seen REAL NOT NULL,
                UNIQUE(account_id,id))""")
            db.execute("""CREATE TABLE IF NOT EXISTS nw_access_sessions (
                session_hash TEXT PRIMARY KEY, account_id TEXT NOT NULL,
                device_id TEXT NOT NULL, revoked INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL, last_seen REAL NOT NULL)""")
            db.execute("CREATE INDEX IF NOT EXISTS nw_access_session_device ON nw_access_sessions(account_id,device_id)")
            db.execute("CREATE INDEX IF NOT EXISTS nw_access_device_account ON nw_access_devices(account_id,seq)")

    @staticmethod
    def _rows(db, account_id):
        return db.execute("SELECT * FROM nw_access_devices WHERE account_id=? ORDER BY seq", (account_id,)).fetchall()

    @staticmethod
    def _session(db, digest):
        row = db.execute("SELECT * FROM nw_access_sessions WHERE session_hash=?", (digest,)).fetchone()
        if row is not None and row["revoked"]:
            raise AccessError(401, "session_revoked", "Сессия этого устройства отозвана. Войдите заново.")
        return row

    def check_session(self, account_id, session_key):
        digest = session_digest(account_id, session_key)
        with self.database.read() as db:
            self._session(db, digest)

    def knows_credential(self, account_id, token):
        try:
            digest = credential_digest(token)
        except AccessError:
            return False
        with self.database.read() as db:
            return db.execute("SELECT 1 FROM nw_access_devices WHERE account_id=? AND token_hash=?",
                              (account_id, digest)).fetchone() is not None

    @staticmethod
    def _require_allowed(rows, device_id, limit):
        if device_id not in {row["id"] for row in rows[:limit]}:
            raise AccessError(409, "device_limit", "Достигнут лимит устройств. Освободите место в списке устройств.")

    @staticmethod
    def _bind(db, digest, account_id, device_id, now):
        db.execute("""INSERT INTO nw_access_sessions
            (session_hash,account_id,device_id,revoked,created_at,last_seen) VALUES(?,?,?,0,?,?)
            ON CONFLICT(session_hash) DO UPDATE SET last_seen=excluded.last_seen""",
                   (digest, account_id, device_id, now, now))

    def register(self, account_id, session_key, *, platform, name, limit_provider,
                 device_id=None, device_token=None):
        if not isinstance(platform, str) or platform not in PLATFORMS:
            raise AccessError(400, "invalid_platform", "Неизвестная платформа устройства.")
        if device_id is not None and (not isinstance(device_id, str) or not DEVICE_ID.fullmatch(device_id)):
            raise AccessError(400, "invalid_device", "Некорректный идентификатор устройства.")
        if not isinstance(name, str) or not name.strip() or len(name) > 160:
            raise AccessError(400, "invalid_name", "Укажите название устройства до 160 символов.")
        digest, now = session_digest(account_id, session_key), self.clock()
        with self.database.transaction() as db:
            session = self._session(db, digest)
            limit = int(limit_provider())
            rows = self._rows(db, account_id)
            found = None
            if device_token is not None:
                token_hash = credential_digest(device_token)
                found = db.execute("SELECT * FROM nw_access_devices WHERE account_id=? AND token_hash=?",
                                   (account_id, token_hash)).fetchone()
                if found is None or (device_id is not None and device_id != found["id"]):
                    raise AccessError(401, "invalid_device_token", "Недействительный ключ устройства.")
            if session is not None:
                current = db.execute("SELECT * FROM nw_access_devices WHERE account_id=? AND id=?",
                                     (account_id, session["device_id"])).fetchone()
                if current is None:
                    raise AccessError(401, "session_revoked", "Сессия отозвана. Войдите заново.")
                if (device_id is not None and device_id != current["id"]) or (found is not None and found["id"] != current["id"]):
                    raise AccessError(409, "session_bound", "Сессия уже привязана к другому устройству.")
                found = current
            if found is not None:
                self._require_allowed(rows, found["id"], limit)
                # A bound authenticated session can recover a lost registration
                # response. Rotating its key invalidates older device credentials.
                if device_token is None:
                    device_token = secrets.token_urlsafe(32)
                db.execute("UPDATE nw_access_devices SET name=?,platform=?,last_seen=?,token_hash=? WHERE account_id=? AND id=?",
                           (name.strip(), platform, now, credential_digest(device_token), account_id, found["id"]))
                device_id = found["id"]
            else:
                if device_id is not None and any(row["id"] == device_id for row in rows):
                    raise AccessError(401, "device_token_required", "Для этого устройства нужен ранее выданный ключ.")
                if len(rows) >= limit:
                    raise AccessError(409, "device_limit", "Достигнут лимит устройств. Освободите место в списке устройств.")
                device_id = device_id or "nw_" + secrets.token_urlsafe(18)
                device_token = secrets.token_urlsafe(32)
                db.execute("INSERT INTO nw_access_devices(account_id,id,token_hash,name,platform,created_at,last_seen) VALUES(?,?,?,?,?,?,?)",
                           (account_id, device_id, credential_digest(device_token), name.strip(), platform, now, now))
            self._bind(db, digest, account_id, device_id, now)
        return {"ok": True, "device_id": device_id, "device_token": device_token, "limit": limit}

    def authorize(self, account_id, session_key, device_token, limit_provider):
        digest, now = session_digest(account_id, session_key), self.clock()
        token_hash = credential_digest(device_token)
        with self.database.transaction() as db:
            session = self._session(db, digest)
            device = db.execute("SELECT * FROM nw_access_devices WHERE account_id=? AND token_hash=?",
                                (account_id, token_hash)).fetchone()
            if device is None:
                raise AccessError(401, "invalid_device_token", "Недействительный ключ устройства.")
            if session is not None and session["device_id"] != device["id"]:
                raise AccessError(401, "device_session_mismatch", "Ключ устройства не соответствует сессии.")
            self._require_allowed(self._rows(db, account_id), device["id"], int(limit_provider()))
            self._bind(db, digest, account_id, device["id"], now)
            if device["last_seen"] < now - 60:
                db.execute("UPDATE nw_access_devices SET last_seen=? WHERE seq=?", (now, device["seq"]))
        return device["id"]

    def list_devices(self, account_id, session_key, limit):
        digest = session_digest(account_id, session_key)
        with self.database.read() as db:
            session = self._session(db, digest)
            rows = self._rows(db, account_id)
        return {"limit": limit, "count": len(rows), "devices": [
            {"id": row["id"], "name": row["name"], "platform": row["platform"],
             "created_at": row["created_at"], "last_seen": row["last_seen"],
             "current": session is not None and session["device_id"] == row["id"],
             "blocked": index >= limit} for index, row in enumerate(rows)]}

    def remove(self, account_id, device_id):
        if not isinstance(device_id, str) or not DEVICE_ID.fullmatch(device_id):
            raise AccessError(400, "invalid_device", "Некорректный идентификатор устройства.")
        with self.database.transaction() as db:
            cursor = db.execute("DELETE FROM nw_access_devices WHERE account_id=? AND id=?", (account_id, device_id))
            if cursor.rowcount == 0:
                raise AccessError(404, "device_not_found", "Устройство не найдено.")
            # Keep tombstones even after deleting the slot. The same live host
            # session cannot simply register again after a remote sign-out.
            db.execute("UPDATE nw_access_sessions SET revoked=1 WHERE account_id=? AND device_id=?",
                       (account_id, device_id))
        return {"ok": True}
