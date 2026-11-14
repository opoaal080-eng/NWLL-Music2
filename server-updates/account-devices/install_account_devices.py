r"""Install or update the account-device registry on a compatible FastAPI server.

Usage:
    python install_account_devices.py --check --target "C:\Nightwell\Server"
    python install_account_devices.py --target "C:\Nightwell\Server"

The installer does not restart the server. Every change is backed up.
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
    """Append the hook once, without touching existing application routes."""
    if MARKER in source:
        return source
    tree = ast.parse(source, filename="app.py")
    defined = {node.name for node in tree.body
               if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))}
    assigned = set()
    for node in tree.body:
        if isinstance(node, ast.Assign):
            assigned.update(target.id for target in node.targets
                            if isinstance(target, ast.Name))
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
            assigned.add(node.target.id)
    if "premium_service" not in assigned or "premium_csrf" not in defined:
        raise RuntimeError("Не найдена действующая проверка Premium и CSRF. Сервер не изменён.")
    if "app" not in assigned or "identity" not in defined:
        raise RuntimeError("Нужны действующие app и identity(request). Сервер не изменён.")
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
    other = target / "account_devices.py"
    needs_hook = changed != original
    needs_module = not other.is_file() or other.read_bytes() != module.read_bytes()

    if check:
        if not needs_hook and not needs_module:
            return "Установлено, серверный модуль актуален."
        return "Совместимо; требуется " + ("установка." if needs_hook else "обновление модуля.")
    if not needs_hook and not needs_module:
        return "Уже установлено; файлы не менялись."

    # Microseconds avoid collisions between consecutive deployment attempts.
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d-%H%M%S-%f")
    backup = target / "backups" / ("account-devices-" + stamp)
    backup.mkdir(parents=True, exist_ok=False)
    shutil.copy2(path, backup / "app.py")
    previous_module = other.is_file()
    if previous_module:
        shutil.copy2(other, backup / "account_devices.py")

    pending_app = target / "app.py.account-devices.tmp"
    pending_module = target / "account_devices.py.account-devices.tmp"
    try:
        if needs_module:
            shutil.copy2(module, pending_module)
            os.replace(pending_module, other)
        if needs_hook:
            pending_app.write_text(changed, encoding="utf-8")
            os.replace(pending_app, path)
    except Exception:
        # If either replacement fails, restore both files, including the module.
        shutil.copy2(backup / "app.py", path)
        if previous_module:
            shutil.copy2(backup / "account_devices.py", other)
        else:
            other.unlink(missing_ok=True)
        raise
    finally:
        pending_app.unlink(missing_ok=True)
        pending_module.unlink(missing_ok=True)

    return "Установлено/обновлено. Перезапусти сервер. Резервная копия: " + str(backup)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", required=True)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    print(install(args.target, args.check))
