"""Additive account profiles, revocable playlist links and web account controls."""
import base64
import binascii
import hashlib
import io
import json
import re
import secrets
import time
import unicodedata
from pathlib import Path

from fastapi import HTTPException, Request
from fastapi.responses import FileResponse, Response
from PIL import Image, ImageOps, UnidentifiedImageError
from starlette.concurrency import run_in_threadpool

MAX_IMAGE = 3 * 1024 * 1024
MAX_BODY = MAX_IMAGE * 4 // 3 + 4096


def normalize_nickname(value):
    if not isinstance(value, str):
        raise HTTPException(400, "Укажи ник")
    value = unicodedata.normalize("NFC", value.strip())
    if not 2 <= len(value) <= 40 or any(unicodedata.category(c).startswith("C") for c in value):
        raise HTTPException(400, "Ник должен содержать от 2 до 40 символов без управляющих знаков")
    return value


def avatar_bytes(encoded):
    if not isinstance(encoded, str) or len(encoded) > MAX_BODY:
        raise HTTPException(413, "Выбери изображение до 3 МБ")
    try:
        data = base64.b64decode(encoded, validate=True)
        if not data or len(data) > MAX_IMAGE:
            raise HTTPException(413, "Выбери изображение до 3 МБ")
        with Image.open(io.BytesIO(data)) as image:
            if image.format not in {"PNG", "JPEG", "WEBP", "BMP"} or image.width * image.height > 24_000_000:
                raise HTTPException(400, "Выбери обычное изображение JPG, PNG или WebP")
            image.load()
            # Drop EXIF, GPS and animation. A bounded square is served as JPEG only.
            rgb = ImageOps.exif_transpose(image).convert("RGB")
            rgb = ImageOps.fit(rgb, (512, 512), method=Image.Resampling.LANCZOS)
            output = io.BytesIO()
            rgb.save(output, "JPEG", quality=88, optimize=True)
            return output.getvalue()
    except (ValueError, binascii.Error, UnidentifiedImageError, OSError, Image.DecompressionBombError) as exc:
        raise HTTPException(400, "Не удалось прочитать изображение") from exc


def install(app, core, session, csrf, public, available=None):
    if getattr(app.state, "nw_profile_workspace", False):
        return
    with core.db() as db:
        db.execute("""CREATE TABLE IF NOT EXISTS nw_profiles (
            user_id TEXT PRIMARY KEY, nickname TEXT NOT NULL DEFAULT '',
            avatar BLOB, revision TEXT NOT NULL DEFAULT '')""")
        db.execute("""CREATE TABLE IF NOT EXISTS nw_collection_shares (
            token TEXT PRIMARY KEY, owner TEXT NOT NULL, kind TEXT NOT NULL,
            playlist_id TEXT NOT NULL, title TEXT NOT NULL, ids TEXT NOT NULL,
            created REAL NOT NULL, revoked INTEGER NOT NULL DEFAULT 0)""")
        db.execute("CREATE INDEX IF NOT EXISTS nw_share_owner ON nw_collection_shares(owner,kind,playlist_id)")

    def identity(request, write=False):
        user = session(request, False)
        if not user:
            raise HTTPException(401, "Войди в аккаунт")
        if write and not csrf(request):
            raise HTTPException(403, "Обнови страницу и повтори действие")
        return str(user["user_id"])

    async def body(request, maximum=MAX_BODY):
        chunks = bytearray()
        async for chunk in request.stream():
            chunks.extend(chunk)
            if len(chunks) > maximum:
                raise HTTPException(413, "Файл слишком большой")
        try:
            value = json.loads(chunks)
        except (ValueError, UnicodeDecodeError):
            raise HTTPException(400, "Неверный формат данных")
        if not isinstance(value, dict):
            raise HTTPException(400, "Неверный формат данных")
        return value

    def profile(uid):
        with core.db() as db:
            row = db.execute("SELECT nickname,revision FROM nw_profiles WHERE user_id=?", (uid,)).fetchone()
        return {"nickname": row[0] if row else "", "avatar_url":
                f"/api/avatars/{uid}/{row[1]}" if row and row[1] else ""}

    @app.get("/api/profile")
    def get_profile(request: Request):
        return profile(identity(request))

    @app.put("/api/profile")
    async def update_profile(request: Request):
        uid = identity(request, True)
        nickname = normalize_nickname((await body(request, 4096)).get("nickname"))
        def save():
            with core.db() as db:
                db.execute("INSERT INTO nw_profiles(user_id,nickname) VALUES(?,?) ON CONFLICT(user_id) DO UPDATE SET nickname=excluded.nickname", (uid, nickname))
            return profile(uid)
        return await run_in_threadpool(save)

    @app.post("/api/profile/avatar")
    async def upload_avatar(request: Request):
        uid = identity(request, True)
        value = await body(request)
        data = await run_in_threadpool(avatar_bytes, value.get("image"))
        revision = secrets.token_hex(12)
        def save():
            with core.db() as db:
                db.execute("INSERT INTO nw_profiles(user_id,avatar,revision) VALUES(?,?,?) ON CONFLICT(user_id) DO UPDATE SET avatar=excluded.avatar,revision=excluded.revision", (uid, data, revision))
            return profile(uid)
        return await run_in_threadpool(save)

    @app.delete("/api/profile/avatar")
    def delete_avatar(request: Request):
        uid = identity(request, True)
        with core.db() as db:
            db.execute("UPDATE nw_profiles SET avatar=NULL,revision='' WHERE user_id=?", (uid,))
        return profile(uid)

    @app.get("/api/avatars/{uid}/{revision}")
    def avatar(uid: str, revision: str, request: Request):
        if uid != identity(request):
            raise HTTPException(404, "Изображение не найдено")
        with core.db() as db:
            row = db.execute("SELECT avatar FROM nw_profiles WHERE user_id=? AND revision=? AND avatar IS NOT NULL", (uid, revision)).fetchone()
        if not row:
            raise HTTPException(404, "Изображение не найдено")
        return Response(bytes(row[0]), media_type="image/jpeg", headers={"Cache-Control": "private, max-age=86400", "X-Content-Type-Options": "nosniff"})

    # Prepend exact share routes to repair older broken implementations while
    # leaving every unrelated route and installed catalog integration intact.
    old_routes = list(app.router.routes)

    @app.post("/api/shares")
    async def create_share(request: Request):
        uid = identity(request, True)
        data = await body(request, 16384)
        kind, pid = data.get("kind"), data.get("playlist_id") or ""
        if kind not in {"playlist", "likes"} or not isinstance(pid, str) or len(pid) > 160:
            raise HTTPException(400, "Выбери плейлист или избранное")
        def create():
            with core.db() as db:
                if kind == "playlist":
                    playlist = db.execute("SELECT name FROM playlists WHERE id=? AND user_id=?", (pid, uid)).fetchone()
                    if not playlist:
                        raise HTTPException(404, "Плейлист не найден")
                    title = playlist[0]
                    ids = [r[0] for r in db.execute("SELECT track_id FROM playlist_tracks WHERE playlist_id=? ORDER BY position", (pid,))]
                else:
                    title = "Избранное"
                    ids = [r[0] for r in db.execute("SELECT track_id FROM likes WHERE user_id=? ORDER BY rowid DESC", (uid,))]
                if not ids:
                    raise HTTPException(400, "В подборке пока нет треков")
                # Repeated clicks reuse the same link and update its snapshot.
                row = db.execute("SELECT token FROM nw_collection_shares WHERE owner=? AND kind=? AND playlist_id=? AND revoked=0 ORDER BY created DESC LIMIT 1", (uid, kind, pid)).fetchone()
                token = row[0] if row else secrets.token_hex(16)
                db.execute("INSERT INTO nw_collection_shares VALUES(?,?,?,?,?,?,?,0) ON CONFLICT(token) DO UPDATE SET title=excluded.title,ids=excluded.ids", (token, uid, kind, pid, title, json.dumps(ids[:10000]), time.time()))
            return {"path": "/playlist/" + token, "token": token, "title": title}
        return await run_in_threadpool(create)

    @app.get("/api/shares/{token}")
    def read_share(token: str, request: Request):
        if not re.fullmatch(r"[a-f0-9]{32}", token):
            raise HTTPException(404, "Подборка не найдена")
        with core.db() as db:
            row = db.execute("SELECT * FROM nw_collection_shares WHERE token=? AND revoked=0", (token,)).fetchone()
            if not row:
                raise HTTPException(404, "Ссылка удалена или не существует")
            if row[2] == "playlist" and not db.execute("SELECT 1 FROM playlists WHERE id=? AND user_id=?", (row[3], row[1])).fetchone():
                raise HTTPException(404, "Плейлист удалён")
            ids = json.loads(row[5]); result = []
            for offset in range(0, len(ids), 400):
                batch = ids[offset:offset+400]
                found = {r["id"]: r for r in db.execute("SELECT * FROM tracks WHERE id IN (" + ",".join("?" for _ in batch) + ")", batch)}
                for tid in batch:
                    track = found.get(tid)
                    if track is None:
                        continue
                    rights = json.loads(track["rights"])
                    if rights.get("status") != "approved" or rights.get("visibility", "shared") != "shared":
                        continue
                    metadata = public(track)
                    result.append({key: metadata.get(key) for key in ("id", "title", "artist", "album", "duration", "cover_url", "source", "is_remote")})
        return {"title": row[4], "tracks": result, "kind": row[2]}

    @app.delete("/api/shares/{token}")
    def revoke_share(token: str, request: Request):
        uid = identity(request, True)
        with core.db() as db:
            result = db.execute("UPDATE nw_collection_shares SET revoked=1 WHERE token=? AND owner=?", (token, uid))
            if result.rowcount == 0:
                raise HTTPException(404, "Ссылка не найдена")
        return {"ok": True}

    @app.get("/playlist/{token}")
    def playlist_page(token: str):
        if not re.fullmatch(r"[a-f0-9]{32}", token):
            raise HTTPException(404, "Ссылка некорректна")
        return FileResponse(Path(core.ROOT) / "web" / "index.html", media_type="text/html", headers={"Cache-Control": "no-cache"})

    new_routes = [route for route in app.router.routes if route not in old_routes]
    app.router.routes[:] = new_routes + old_routes
    asset = Path(__file__).with_name("profile-workspace.js")

    @app.get("/profile-workspace.js")
    def web_asset():
        return FileResponse(asset, media_type="text/javascript", headers={"Cache-Control": "no-cache"})
    # The existing /{asset} catch-all must not mask this named asset route.
    app.router.routes.insert(0, app.router.routes.pop())
    app.state.nw_profile_workspace = True
