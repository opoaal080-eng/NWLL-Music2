"""Conservative installer for the Nightwell FastAPI artist catalog.

Refuses unknown server layouts; makes timestamped backups before any changes.
"""
import argparse
import ast
import datetime
import os
import shutil
from pathlib import Path

HOOK_MARKER = "# Nightwell artist directory module"
HOOK = """
# Nightwell artist directory module
from pathlib import Path as _NightwellPath
from artist_catalog import install as _install_nightwell_artist_directory
_install_nightwell_artist_directory(
    app, identity, db_path=_NightwellPath(__file__).resolve().with_name("artist_catalog.sqlite3"))
"""


def patch_server(contents):
    tree = ast.parse(contents, filename="app.py")
    if HOOK_MARKER in contents:
        return contents, False
    has_app = any(
        isinstance(node, (ast.Assign, ast.AnnAssign)) and any(
            isinstance(target, ast.Name) and target.id == "app"
            for target in (node.targets if isinstance(node, ast.Assign) else [node.target]))
        for node in ast.walk(tree)
    )
    has_identity = any(
        isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == "identity"
        for node in tree.body
    )
    if not has_app or not has_identity or "/api/tracks" not in contents:
        raise RuntimeError(
            "Версия app.py неизвестна: нужны FastAPI app, функция identity(request) "
            "и маршрут /api/tracks. Модуль не установлен, проверь README-RU.md.")
    starts = [
        node.lineno for node in tree.body if isinstance(node, ast.If)
        and isinstance(node.test, ast.Compare)
        and isinstance(node.test.left, ast.Name) and node.test.left.id == "__name__"
    ]
    lines = contents.splitlines(keepends=True)
    index = min(starts) - 1 if starts else len(lines)
    prefix = "".join(lines[:index])
    suffix = "".join(lines[index:])
    new_source = prefix.rstrip() + "\n" + HOOK + "\n" + suffix
    ast.parse(new_source, filename="app.py")
    return new_source, True


def install(target):
    target = Path(target).expanduser().resolve()
    app_file = target / "app.py"
    payload = Path(__file__).with_name("artist_catalog.py")
    if not app_file.is_file() or not payload.is_file():
        raise RuntimeError("Не найдены app.py на сервере или artist_catalog.py рядом с установщиком")
    app_old = app_file.read_text(encoding="utf-8-sig")
    updated, changed = patch_server(app_old)
    files = {
        app_file: updated.encode("utf-8"),
        target / "artist_catalog.py": payload.read_bytes(),
    }
    backup = target / "backups" / ("artist-catalog-" +
        datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f"))
    backup.mkdir(parents=True, exist_ok=False)
    written = []
    try:
        for path, data in files.items():
            old = backup / path.name
            if path.exists():
                shutil.copy2(path, old)
            if path.exists() and path.read_bytes() == data:
                continue
            temporary = path.with_name(path.name + ".artist-new")
            try:
                temporary.write_bytes(data)
                os.replace(temporary, path)
                written.append(path)
            finally:
                if temporary.exists():
                    temporary.unlink()
    except Exception:
        for path in reversed(written):
            old = backup / path.name
            if old.exists():
                shutil.copy2(old, path)
            else:
                path.unlink(missing_ok=True)
        raise
    return backup, changed


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", default=r"C:\Nightwell Music\nightwell-music")
    args = parser.parse_args()
    location, changed = install(args.target)
    print("Резервная копия:", location)
    print("Хук добавлен в app.py:", "да" if changed else "уже был")
    print("Теперь перезапусти существующий сервер Nightwell Music.")
