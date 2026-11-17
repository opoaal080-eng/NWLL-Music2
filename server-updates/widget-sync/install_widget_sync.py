"""Safely install the Nightwell widget API into an existing FastAPI app.py.

Run with --check first. The running server is not restarted automatically.
"""
import argparse
import ast
import datetime
import os
from pathlib import Path
import shutil

MARKER = "# Nightwell private WidgetKit sync module"
HOOK = '''
# Nightwell private WidgetKit sync module
from widget_sync import install as _nw_install_widget_sync
_nw_install_widget_sync(
    app, identity,
    db_path=Path(__file__).resolve().with_name("widget_sync.sqlite3"),
    csrf_verifier=premium_csrf)
'''


def patch(source):
    if MARKER in source:
        return source
    tree = ast.parse(source, filename="app.py")
    defined = {n.name for n in tree.body
               if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))}
    assigned = set()
    for node in tree.body:
        if isinstance(node, ast.Assign):
            assigned.update(t.id for t in node.targets if isinstance(t, ast.Name))
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
            assigned.add(node.target.id)
    if not {"identity", "premium_csrf"}.issubset(defined) or "app" not in assigned:
        raise RuntimeError("Нужны существующие FastAPI app, identity и premium_csrf. app.py не изменён.")
    if "/api/widgets/" in source:
        raise RuntimeError("Маршруты виджетов уже присутствуют: требуется ручная проверка.")
    has_path = any(isinstance(n, ast.ImportFrom) and n.module == "pathlib"
                   and any(a.name == "Path" for a in n.names) for n in tree.body)
    insert = next((n.lineno - 1 for n in tree.body if isinstance(n, ast.If)
                   and isinstance(n.test, ast.Compare)
                   and isinstance(n.test.left, ast.Name) and n.test.left.id == "__name__"),
                  len(source.splitlines()))
    lines = source.splitlines(keepends=True)
    prelude = "" if has_path else "from pathlib import Path\n"
    result = "".join(lines[:insert]).rstrip() + "\n\n" + prelude + HOOK + "\n" + "".join(lines[insert:])
    ast.parse(result)
    return result


def install(target, check=False):
    target = Path(target).expanduser().resolve()
    original_path = target / "app.py"
    module = Path(__file__).with_name("widget_sync.py")
    destination = target / "widget_sync.py"
    if not original_path.is_file() or not module.is_file():
        raise RuntimeError("Нужен существующий app.py и файл widget_sync.py.")
    if original_path.is_symlink() or destination.is_symlink():
        raise RuntimeError("Установка через символические ссылки запрещена.")
    original = original_path.read_text("utf-8-sig")
    revised = patch(original)
    changed_app = revised != original
    changed_mod = not destination.is_file() or destination.read_bytes() != module.read_bytes()
    if check:
        return "Совместимо. app.py: " + ("обновить" if changed_app else "без изменений") + (
            ", модуль: обновить" if changed_mod else ", модуль: актуален")
    if not (changed_app or changed_mod):
        return "Модуль виджетов уже установлен."
    backup = target / "backups" / ("widget-sync-" + datetime.datetime.now(
        datetime.timezone.utc).strftime("%Y%m%d-%H%M%S-%f"))
    backup.mkdir(parents=True, exist_ok=False)
    shutil.copy2(original_path, backup / "app.py")
    if destination.is_file():
        shutil.copy2(destination, backup / "widget_sync.py")
    t_app = target / "app.py.widget-sync.tmp"
    t_mod = target / "widget_sync.py.widget-sync.tmp"
    try:
        if changed_mod:
            shutil.copy2(module, t_mod)
            os.replace(t_mod, destination)
        if changed_app:
            t_app.write_text(revised, encoding="utf-8")
            os.replace(t_app, original_path)
    except Exception:
        shutil.copy2(backup / "app.py", original_path)
        if (backup / "widget_sync.py").exists():
            shutil.copy2(backup / "widget_sync.py", destination)
        elif changed_mod:
            destination.unlink(missing_ok=True)
        raise
    finally:
        t_app.unlink(missing_ok=True)
        t_mod.unlink(missing_ok=True)
    return "Установлено. Резервная копия: " + str(backup) + ". Перезапусти сервер штатным способом."


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", required=True)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    print(install(args.target, args.check))
