"""Windows installer: only Nightwell Music's newest artist and source-quality fixes.

Copies 3 server modules; adds 2 integrations to a compatible FastAPI app.py.
Never installs older mail, premium, transfer or daily-playlist modules.
Use --check, --target, --rollback. Original files are backed up atomically.
"""
import argparse
import ast
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys

BANNER_SESSION = "# Nightwell session identity compatibility"
SESSION_IDENTITY_ADAPTER = """
# Nightwell session identity compatibility
def identity(request):
    # Older Nightwell servers authenticate through session(request, required=False).
    # Keep the existing account id and session permissions. Never create a new login.
    account = session(request, False)
    return str(account['user_id']) if account and account.get('user_id') else None
"""

BANNER_ARTIST = "# Nightwell artist directory module"
BANNER_QUALITY = "# Nightwell SoundCloud audio quality module"
FILES = ("artist_catalog.py", "artist_metadata.py", "audio_quality.py", "soundcloud_proxy.py")
HOOKS = [
    (BANNER_ARTIST, """
# Nightwell artist directory module
from pathlib import Path as _NWArtistPath
from artist_catalog import install as _nw_install_artist_catalog
_nw_install_artist_catalog(
    app, identity, db_path=_NWArtistPath(__file__).resolve().with_name("artist_catalog.sqlite3"))
"""),
    (BANNER_QUALITY, """
# Nightwell SoundCloud audio quality module
from audio_quality import install as _nw_install_audio_quality
_nw_install_audio_quality(app, identity)
"""),
]


def patch(contents):
    tree = ast.parse(contents, "app.py")
    names = set()
    identity_found = False
    legacy_session = False
    for node in tree.body:
        if isinstance(node, ast.Assign):
            names.update(t.id for t in node.targets if isinstance(t, ast.Name))
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
            names.add(node.target.id)
        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            if node.name == "identity":
                identity_found = True
            if node.name == "session" and isinstance(node, ast.FunctionDef):
                args = node.args
                required_optional = len(args.args) >= 2 and args.args[0].arg == "request" and args.args[1].arg == "required"
                safe_optional = (len(args.defaults) >= 1 and
                                 isinstance(args.defaults[-1], ast.Constant) and
                                 args.defaults[-1].value is True)
                # Only adapt the legacy Nightwell session contract, never an
                # arbitrary auth function from a different FastAPI project.
                session_body = ast.get_source_segment(contents, node) or ""
                legacy_session = bool(
                    required_optional and safe_optional and
                    ("sessions.user_id" in session_body or
                     "'user_id'" in session_body or
                     '"user_id"' in session_body) and
                    "return dict(row)" in session_body
                )
    has_tracks = "/api/tracks" in contents
    has_stream = "/api/stream" in contents
    if "app" not in names or not has_tracks or not has_stream:
        raise ValueError("Текущий app.py не распознан. Нужны app, "
                         "/api/tracks и /api/stream. Файлы не изменены.")
    if not identity_found and not legacy_session:
        raise ValueError("Не найдена совместимая авторизация. Нужен "
                         "identity(request) или session(request, required=True) "
                         "с user_id. Пришли действующий app.py для точной интеграции.")
    if "identity" in names and not identity_found:
        raise ValueError("В app.py есть переменная identity неизвестного вида. "
                         "Не заменяем существующую авторизацию.")
    if "/api/artists" in contents and BANNER_ARTIST not in contents:
        raise ValueError("У сервера уже существует другой /api/artists. Изменения не применены.")
    if "/api/audio-quality/" in contents and BANNER_QUALITY not in contents:
        raise ValueError("У сервера уже существует другой /api/audio-quality/.")
    additions = []
    if not identity_found and legacy_session:
        additions.append(SESSION_IDENTITY_ADAPTER)
    additions.extend(text for banner, text in HOOKS if banner not in contents)
    if not additions:
        return contents
    lines = contents.splitlines(keepends=True)
    starts = [
        node.lineno - 1 for node in tree.body
        if isinstance(node, ast.If) and isinstance(node.test, ast.Compare)
        and isinstance(node.test.left, ast.Name) and node.test.left.id == "__name__"
    ]
    at = min(starts) if starts else len(lines)
    updated = "".join(lines[:at]).rstrip() + "\n\n" + "\n".join(additions) + "\n" + "".join(lines[at:])
    ast.parse(updated, "app.py")
    return updated


def checksum(data):
    return hashlib.sha256(data).hexdigest()


def prepare(root, source=None):
    root = Path(root).expanduser().resolve()
    source = Path(source or Path(__file__).parent).resolve()
    app_file = root / "app.py"
    if not app_file.is_file() or app_file.is_symlink():
        raise ValueError("Не найден обычный app.py: " + str(app_file))
    data = app_file.read_text(encoding="utf-8-sig")
    desired = {"app.py": patch(data).encode("utf-8")}
    for name in FILES:
        file = source / name
        if not file.is_file():
            raise ValueError("Пакет неполный: отсутствует " + str(file))
        payload = file.read_bytes()
        ast.parse(payload.decode("utf-8"), filename=name)
        desired[name] = payload
    for name in desired:
        if (root / name).is_symlink():
            raise ValueError("Нельзя перезаписывать ссылку " + name)
    return root, desired


def check(root, source=None):
    target, desired = prepare(root, source)
    changes = []
    for name, data in desired.items():
        destination = target / name
        old = destination.read_bytes() if destination.is_file() else None
        state = "add" if old is None else "same" if old == data else "update"
        changes.append({"file": name, "state": state})
    return {"target": str(target), "changes": changes}


def install(root, source=None):
    target, desired = prepare(root, source)
    changes = check(root, source)["changes"]
    updates = [x["file"] for x in changes if x["state"] != "same"]
    if not updates:
        return None, changes
    backup = target / "backups" / ("nw-latest-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f"))
    backup.mkdir(parents=True, exist_ok=False)
    (backup / "previous").mkdir()
    entries = []
    written = []
    try:
        for name in updates:
            file = target / name
            previous = file.read_bytes() if file.is_file() else None
            if previous is not None:
                shutil.copy2(file, backup / "previous" / name)
            entries.append({
                "name": name, "old": previous is not None,
                "new_sha256": checksum(desired[name]),
            })
        (backup / "manifest.json").write_text(json.dumps(
            {"target": str(target), "entries": entries}, ensure_ascii=False, indent=2),
            encoding="utf-8")
        for name in updates:
            file = target / name
            temporary = target / (name + ".nw-new")
            try:
                temporary.write_bytes(desired[name])
                os.replace(temporary, file)
                written.append(name)
            finally:
                temporary.unlink(missing_ok=True)
    except BaseException:
        for name in reversed(written):
            saved = backup / "previous" / name
            if saved.is_file():
                shutil.copy2(saved, target / name)
            else:
                (target / name).unlink(missing_ok=True)
        raise
    return backup, changes


def rollback(folder):
    folder = Path(folder).expanduser().resolve()
    manifest = json.loads((folder / "manifest.json").read_text(encoding="utf-8"))
    root = Path(manifest["target"]).resolve()
    for item in manifest["entries"]:
        if item["name"] not in ("app.py", *FILES):
            raise ValueError("Неожиданный файл резервной копии")
        dest = root / item["name"]
        if dest.is_symlink() or not dest.is_file() or checksum(dest.read_bytes()) != item["new_sha256"]:
            raise ValueError("Файл изменился после установки: " + item["name"])
        if item["old"] and not (folder / "previous" / item["name"]).is_file():
            raise ValueError("Не найдена резервная копия: " + item["name"])
    for item in manifest["entries"]:
        dest = root / item["name"]
        if item["old"]:
            shutil.copy2(folder / "previous" / item["name"], dest)
        else:
            dest.unlink()
    return root


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", default=r"C:\Nightwell Music\nightwell-music")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--rollback")
    args = parser.parse_args(argv)
    try:
        if args.rollback:
            print("Откат выполнен:", rollback(args.rollback))
        elif args.check:
            print(json.dumps(check(args.target), ensure_ascii=False, indent=2))
        else:
            backup, changes = install(args.target)
            print(json.dumps(changes, ensure_ascii=False, indent=2))
            print("Резервная копия:", backup if backup else "изменения уже установлены")
            print("Перезапусти Nightwell Music своим старым батником.")
        return 0
    except (OSError, ValueError, SyntaxError) as exc:
        print("Установка остановлена: " + str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
