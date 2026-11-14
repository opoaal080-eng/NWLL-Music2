"""Install the account device registry alongside the current Nightwell FastAPI server.

Usage:
    python install_account_devices.py --target "C:\Nightwell\Server"
    python install_account_devices.py --check --target "C:\Nightwell\Server"

Restarts are not automatic. The installer creates a timestamped copy of app.py.
"""
import argparse
import ast
import datetime
import os
from pathlib import Path
import shutil

HOOK = """
# Nightwell per-account device registry
from account_devices import install as _nw_install_account_devices

def _nw_is_premium_device_owner(account_id):
    try:
        premium_service.require(str(account_id))
        return True
    except Exception:
        return False

_nw_install_account_devices(
    app, identity,
    db_path=Path(__file__).resolve().with_name("account_devices.sqlite3"),
    premium_for_account=_nw_is_premium_device_owner,
    csrf_verifier=premium_csrf)
"""
MARKER = "# Nightwell per-account device registry"


def patch(source):
    tree = ast.parse(source, filename="app.py")
    defined = {node.name for node in tree.body
               if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))}
    assigned = {target.id for node in tree.body if isinstance(node, ast.Assign)
                for target in node.targets if isinstance(target, ast.Name)}
    if "premium_service" not in assigned or "premium_csrf" not in defined:
        raise RuntimeError("Не найдена действующая проверка Premium и CSRF. Сервер не изменён.")
    if "app" not in assigned or "identity" not in defined:
        raise RuntimeError("Нужны действующие app и identity(request). Сервер не изменён.")
    if MARKER in source:
        return source
    if "/api/devices" in source:
        raise RuntimeError("У сервера уже есть маршруты /api/devices; проверь их вручную.")
    headers = "from pathlib import Path\n" if not any(
        isinstance(node, ast.ImportFrom) and node.module == "pathlib" and
        any(alias.name == "Path" for alias in node.names) for node in tree.body) else ""
    main = next((node.lineno - 1 for node in tree.body if isinstance(node, ast.If)
                 and isinstance(node.test, ast.Compare) and
                 isinstance(node.test.left, ast.Name) and node.test.left.id == "__name__"),
                len(source.splitlines()))
    lines = source.splitlines(keepends=True)
    result = "".join(lines[:main]).rstrip() + "\n\n" + headers + HOOK + "\n" + "".join(lines[main:])
    ast.parse(result, filename="app.py")
    return result


def install(target, check=False):
    target = Path(target).resolve()
    path = target / "app.py"
    module = Path(__file__).with_name("account_devices.py")
    if not path.is_file() or not module.is_file():
        raise RuntimeError("Не найден app.py или модуль account_devices.py.")
    original = path.read_text(encoding="utf-8-sig")
    changed = patch(original)
    if check:
        return "Совместимо; требуется обновление." if changed != original else "Модуль уже установлен."
    if changed == original:
        return "Уже установлен; файлы не менялись."
    backup = target / "backups" / ("account-devices-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
    backup.mkdir(parents=True)
    shutil.copy2(path, backup / "app.py")
    other = target / "account_devices.py"
    if other.exists():
        shutil.copy2(other, backup / "account_devices.py")
    pending = target / "app.py.account-devices.tmp"
    try:
        shutil.copy2(module, other)
        pending.write_text(changed, encoding="utf-8")
        os.replace(pending, path)
    except Exception:
        pending.unlink(missing_ok=True)
        shutil.copy2(backup / "app.py", path)
        raise
    return "Установлено. Перезапусти сервер. Резервная копия: " + str(backup)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", required=True)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    print(install(args.target, args.check))
