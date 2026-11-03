"""Transactional installer for Nightwell Music's compatible Windows FastAPI backend.

This package does NOT include the running main app.py. The installer inspects
the existing app.py, patches only known route layouts, and keeps exact
rollback backups. Premium entitlements and email authentication are staged,
never enabled without operator configuration.
"""
import argparse
import ast
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys

ARTIST_MARKER = "# Nightwell artist directory module"
DAILY_MARKER = "# Nightwell daily public playlists module"

ARTIST_HOOK = """
# Nightwell artist directory module
from pathlib import Path as _NWArtistPath
from artist_catalog import install as _nw_install_artist_catalog
_nw_install_artist_catalog(
    app, identity,
    db_path=_NWArtistPath(__file__).resolve().with_name("artist_catalog.sqlite3"))
"""

DAILY_HOOK = """
# Nightwell daily public playlists module
from pathlib import Path as _NWPublicPath
from daily_public_playlists import install as _nw_install_daily_public_playlists
_nw_install_daily_public_playlists(
    app, identity,
    db_path=_NWPublicPath(__file__).resolve().with_name("nightwell_daily_playlists.sqlite3"))
"""

PACKAGE_ROOT = Path(__file__).resolve().parents[2]
SOURCES = {
    "artist_catalog.py": "server-updates/artist-catalog/artist_catalog.py",
    "artist_metadata.py": "server-updates/artist-catalog/artist_metadata.py",
    "daily_public_playlists.py": "server-updates/daily-public-playlists/daily_public_playlists.py",
    "music_import.py": "server-updates/playlist-transfer/music_import.py",
    "music_import_sources.py": "server-updates/playlist-transfer/music_import_sources.py",
}


def top_level_app_and_identity(tree):
    assigned_app = False
    defined_identity = False
    for node in tree.body:
        if isinstance(node, ast.Assign):
            assigned_app |= any(isinstance(t, ast.Name) and t.id == "app"
                                for t in node.targets)
        if isinstance(node, ast.AnnAssign):
            assigned_app |= isinstance(node.target, ast.Name) and node.target.id == "app"
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == "identity":
            defined_identity = True
    return assigned_app and defined_identity


def patch_app(contents):
    tree = ast.parse(contents, filename="app.py")
    if not top_level_app_and_identity(tree) or "/api/tracks" not in contents:
        raise RuntimeError(
            "Неизвестная версия app.py: необходимы верхнеуровневые app, "
            "identity(request) и /api/tracks. Главный файл оставлен без изменений.")
    for route, marker in [
        ("/api/artists", ARTIST_MARKER),
        ("/api/daily-public-playlists", DAILY_MARKER),
    ]:
        if route in contents and marker not in contents:
            raise RuntimeError(
                "В app.py найден маршрут " + route +
                " без метки установленного модуля. Чтобы не создать дубль, "
                "автоматическая установка отменена.")
    hooks = []
    if ARTIST_MARKER not in contents:
        hooks.append(ARTIST_HOOK)
    if DAILY_MARKER not in contents:
        hooks.append(DAILY_HOOK)
    if not hooks:
        return contents, []
    starts = [
        node.lineno for node in tree.body
        if isinstance(node, ast.If) and isinstance(node.test, ast.Compare)
        and isinstance(node.test.left, ast.Name)
        and node.test.left.id == "__name__"
    ]
    lines = contents.splitlines(keepends=True)
    insert_at = min(starts) - 1 if starts else len(lines)
    prefix, suffix = "".join(lines[:insert_at]), "".join(lines[insert_at:])
    result = prefix.rstrip() + "\n\n" + "\n".join(hooks) + "\n" + suffix
    ast.parse(result, filename="app.py")
    return result, [ARTIST_MARKER if x == ARTIST_HOOK else DAILY_MARKER for x in hooks]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def build_changes(target, package_root=PACKAGE_ROOT):
    target = Path(target).expanduser().resolve()
    app_file = target / "app.py"
    if not app_file.is_file():
        raise RuntimeError("Не найден app.py в " + str(target) +
                           ". Передай папку действующего сервера через --target")
    if app_file.is_symlink():
        raise RuntimeError("app.py является ссылкой, автоматическое изменение отключено")
    original = app_file.read_text(encoding="utf-8-sig")
    patched, hooks = patch_app(original)
    changes = {"app.py": patched.encode("utf-8")}
    for dest, relative in SOURCES.items():
        source = Path(package_root) / relative
        if not source.is_file():
            raise RuntimeError("В архиве не хватает файла: " + relative)
        data = source.read_bytes()
        if relative.endswith(".py"):
            ast.parse(data.decode("utf-8"), filename=relative)
        changes[dest] = data
    return target, changes, hooks


def plan(target, package_root=PACKAGE_ROOT):
    target, changes, hooks = build_changes(target, package_root)
    items = []
    for name, data in changes.items():
        destination = target / name
        if destination.is_symlink():
            raise RuntimeError("Недопустимая ссылка в папке сервера: " + name)
        original = destination.read_bytes() if destination.exists() else None
        items.append({
            "file": name, "action": "add" if original is None else
            ("unchanged" if original == data else "update"),
        })
    return {"target": str(target), "hooks": hooks, "files": items}


def apply(target, package_root=PACKAGE_ROOT):
    target, changes, hooks = build_changes(target, package_root)
    prospective = plan(target, package_root)
    changed = [entry for entry in prospective["files"]
               if entry["action"] != "unchanged"]
    if not changed:
        return None, prospective

    backup = target / "backups" / (
        "nightwell-server-update-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S-%f"))
    backup.mkdir(parents=True, exist_ok=False)
    previous = backup / "original"
    previous.mkdir()
    entries = []
    replaced = []
    try:
        for item in changed:
            name = item["file"]
            destination = target / name
            original = destination.read_bytes() if destination.exists() else None
            if original is not None:
                shutil.copy2(destination, previous / name)
            entries.append({
                "file": name, "existed": original is not None,
                "before_sha256": sha(original) if original is not None else None,
                "after_sha256": sha(changes[name]),
            })

        manifest = {
            "target": str(target), "created": dt.datetime.now(dt.timezone.utc).isoformat(),
            "entries": entries, "hooks": hooks,
            "note": "Без обновления работающего сервера до перезапуска его службы",
        }
        (backup / "manifest.json").write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")

        for item in changed:
            name = item["file"]
            destination = target / name
            temporary = destination.with_name(destination.name + ".nw-update-new")
            try:
                temporary.write_bytes(changes[name])
                os.replace(temporary, destination)
                replaced.append(destination)
            finally:
                temporary.unlink(missing_ok=True)
    except Exception:
        for destination in reversed(replaced):
            old = previous / destination.name
            if old.is_file():
                shutil.copy2(old, destination)
            else:
                destination.unlink(missing_ok=True)
        raise
    return backup, prospective


def rollback(backup_path):
    backup = Path(backup_path).expanduser().resolve()
    manifest_file = backup / "manifest.json"
    if not manifest_file.is_file():
        raise RuntimeError("В папке резервной копии нет manifest.json")
    manifest = json.loads(manifest_file.read_text(encoding="utf-8"))
    target = Path(manifest["target"]).resolve()
    # Refuse to overwrite a server file that changed AFTER installation.
    for entry in manifest["entries"]:
        name = entry["file"]
        if name not in SOURCES and name != "app.py":
            raise RuntimeError("В резервной копии неожиданное имя: " + name)
        destination = target / name
        if destination.is_symlink():
            raise RuntimeError("Обнаружена ссылка: " + name)
        if not destination.is_file() or sha(destination.read_bytes()) != entry["after_sha256"]:
            raise RuntimeError("После установки файл " + name +
                               " изменился. Автоматический откат отменён.")
        if entry["existed"] and not (backup / "original" / name).is_file():
            raise RuntimeError("Отсутствует исходная копия: " + name)
    for entry in manifest["entries"]:
        destination = target / entry["file"]
        if entry["existed"]:
            shutil.copy2(backup / "original" / entry["file"], destination)
        else:
            destination.unlink()
    return target


def main():
    parser = argparse.ArgumentParser(description="Nightwell Music — проверяемое серверное обновление")
    parser.add_argument("--target", default=r"C:\Nightwell Music\nightwell-music",
                        help="Каталог установленного сервера с app.py")
    parser.add_argument("--check", action="store_true", help="Только проверить, ничего не менять")
    parser.add_argument("--rollback", help="Папка резервной копии из backups для безопасного отката")
    args = parser.parse_args()
    try:
        if args.rollback:
            print("Восстановлено в", rollback(args.rollback))
            return 0
        if args.check:
            print(json.dumps(plan(args.target), ensure_ascii=False, indent=2))
            return 0
        backup, result = apply(args.target)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        if backup:
            print("Резервная копия:", backup)
        print("Готово. Перезапусти существующий сервер штатным батником.")
        print("Email, платежи и прочие интеграции не включались автоматически.")
        return 0
    except (OSError, SyntaxError, ValueError, RuntimeError) as exc:
        print("ОШИБКА: " + str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
