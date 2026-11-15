"""Explicit, reversible installer for the account-access server module.

It never imports the production app, guesses cookie names, edits payment records,
creates a database, or restarts a service. A configured host adapter is required.
"""
from __future__ import annotations

import argparse
import ast
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import sys
import tempfile
from typing import Any

BEGIN = "# BEGIN NIGHTWELL ACCOUNT ACCESS v1"
END = "# END NIGHTWELL ACCOUNT ACCESS v1"
OLD_MARKER = "# Nightwell per-account device registry"
REQUIRED_MODULES = (
    "access_database.py", "family_access.py", "device_access.py", "account_access.py", "family_page.html",
)
OPTIONAL_MODULES = ()
ADAPTER_NAME = "account_access_host.py"
ALLOWED_FILES = frozenset(("app.py", ADAPTER_NAME) + REQUIRED_MODULES + OPTIONAL_MODULES)
HOOK = '''# BEGIN NIGHTWELL ACCOUNT ACCESS v1
from pathlib import Path as _NWAccountAccessPath
from account_access import install as _nw_install_account_access
from account_access_host import configure as _nw_configure_account_access

_nw_account_access_controller = _nw_configure_account_access(
    app=app,
    identity=identity,
    premium_service=premium_service,
    csrf_verifier=premium_csrf,
    module_install=_nw_install_account_access,
    database_path=_NWAccountAccessPath(__file__).resolve().with_name("account_access.sqlite3"),
    public_origin="https://music.nightwell.fun",
    enforce=True,
)
if _nw_account_access_controller is None:
    raise RuntimeError("Account-access adapter did not return an AccessController")
app.state.nightwell_account_access = _nw_account_access_controller
# END NIGHTWELL ACCOUNT ACCESS v1'''


class InstallError(RuntimeError):
    pass


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _text(data: bytes, filename: str) -> str:
    try:
        return data.decode("utf-8-sig")
    except UnicodeDecodeError as error:
        raise InstallError(f"{filename}: нужен исходник в UTF-8, файлы не изменены.") from error


def _parse(source: str, filename: str) -> ast.Module:
    try:
        tree = ast.parse(source, filename=filename)
        compile(source, filename, "exec")
        return tree
    except SyntaxError as error:
        raise InstallError(f"{filename}: ошибка Python в строке {error.lineno}; файлы не изменены.") from error


def _top_level_names(nodes: list[ast.stmt]) -> set[str]:
    names = set()
    for node in nodes:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            names.add(node.name)
        elif isinstance(node, ast.Assign):
            names.update(t.id for t in node.targets if isinstance(t, ast.Name))
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
            names.add(node.target.id)
        elif isinstance(node, (ast.Import, ast.ImportFrom)):
            for alias in node.names:
                names.add(alias.asname or alias.name.split(".")[0])
    return names


def _is_main_guard(node: ast.stmt) -> bool:
    if not isinstance(node, ast.If) or not isinstance(node.test, ast.Compare):
        return False
    test = node.test
    if len(test.ops) != 1 or not isinstance(test.ops[0], ast.Eq) or len(test.comparators) != 1:
        return False
    left, right = test.left, test.comparators[0]
    return (
        isinstance(left, ast.Name) and left.id == "__name__" and
        isinstance(right, ast.Constant) and right.value == "__main__"
    ) or (
        isinstance(right, ast.Name) and right.id == "__name__" and
        isinstance(left, ast.Constant) and left.value == "__main__"
    )


def patch(source: str) -> str:
    """Add only the owned integration block, before the existing main guard."""
    if OLD_MARKER in source or "_nw_install_account_devices" in source:
        raise InstallError(
            "Найден старый реестр account_devices. Сначала выполните ручную миграцию "
            "его hook и клиентов; два ограничителя одновременно не устанавливаются."
        )
    if source.count(BEGIN) != source.count(END) or source.count(BEGIN) > 1:
        raise InstallError("Повреждён или повторён managed-блок account-access; нужна ручная проверка.")
    clean = source
    if BEGIN in source:
        block = re.compile(
            r"(?m)^" + re.escape(BEGIN) + r"\r?\n.*?^" + re.escape(END) + r"(?:\r?\n|$)",
            re.S,
        )
        clean, count = block.subn("", source)
        if count != 1:
            raise InstallError("Не удалось однозначно распознать managed-блок account-access.")
    tree = _parse(clean, "app.py")
    guards = [node for node in tree.body if _is_main_guard(node)]
    if len(guards) > 1:
        raise InstallError("Найдено несколько __main__-блоков; установите интеграцию вручную.")
    guard = guards[0] if guards else None
    before = [node for node in tree.body if guard is None or node.lineno < guard.lineno]
    aliases = {"uvicorn": "uvicorn", "asyncio": "asyncio", "hypercorn": "hypercorn"}
    for node in before:
        if isinstance(node, ast.Import):
            for alias in node.names:
                aliases[alias.asname or alias.name.split(".")[0]] = alias.name
        elif isinstance(node, ast.ImportFrom) and node.module:
            for alias in node.names:
                aliases[alias.asname or alias.name] = node.module + "." + alias.name

    def call_name(value):
        if isinstance(value, ast.Name):
            return aliases.get(value.id, value.id)
        if isinstance(value, ast.Attribute):
            parent = call_name(value.value)
            return parent + "." + value.attr if parent else ""
        return ""

    blocking = {"uvicorn.run", "uvicorn.main.run", "hypercorn.asyncio.serve", "asyncio.run"}
    for statement in before:
        if isinstance(statement, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            continue
        for node in ast.walk(statement):
            if isinstance(node, ast.Call) and call_name(node.func) in blocking:
                raise InstallError("Сервер запускается до места hook. Перенесите запуск в __main__ или подключите модуль вручную.")
    required = {"app", "identity", "premium_service", "premium_csrf"}
    missing = required - _top_level_names(before)
    if missing:
        raise InstallError("В app.py до запуска не найдены: " + ", ".join(sorted(missing)) + ".")
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            for decorator in node.decorator_list:
                if not isinstance(decorator, ast.Call) or not decorator.args:
                    continue
                value = decorator.args[0]
                if isinstance(value, ast.Constant) and isinstance(value.value, str):
                    route = value.value
                    if (route == "/api/devices" or route.startswith("/api/devices/") or
                            route == "/api/family" or route.startswith("/api/family/") or
                            route == "/api/account/access" or route == "/family"):
                        raise InstallError(f"Маршрут {route} уже существует; нужна ручная интеграция.")
    newline = "\r\n" if "\r\n" in clean else "\n"
    lines = clean.splitlines(keepends=True)
    index = guard.lineno - 1 if guard else len(lines)
    prefix = "".join(lines[:index]).rstrip("\r\n")
    suffix = "".join(lines[index:]).lstrip("\r\n")
    result = prefix + newline * 2 + HOOK.replace("\n", newline) + newline * 2 + suffix
    _parse(result, "app.py (patched)")
    return result


def validate_adapter(data: bytes) -> None:
    """A literal marker makes the operator's completed adaptation explicit."""
    tree = _parse(_text(data, ADAPTER_NAME), ADAPTER_NAME)
    flags = []
    functions = []
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(
                isinstance(target, ast.Name) and target.id == "ADAPTER_CONFIGURED"
                for target in node.targets):
            flags.append(node.value)
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name) and node.target.id == "ADAPTER_CONFIGURED":
            flags.append(node.value)
        elif isinstance(node, ast.FunctionDef) and node.name == "configure":
            functions.append(node)
    if len(flags) != 1 or not isinstance(flags[0], ast.Constant) or flags[0].value is not True:
        raise InstallError(
            "Адаптер не подтверждён: настройте account_access_host.py и явно задайте "
            "ADAPTER_CONFIGURED = True. Шаблон нельзя установить как готовую интеграцию."
        )
    if len(functions) != 1:
        raise InstallError("Адаптер должен явно определять одну синхронную функцию configure(...).")
    args = functions[0].args
    names = {arg.arg for arg in args.args + args.kwonlyargs}
    needed = {"app", "identity", "premium_service", "csrf_verifier", "module_install",
              "database_path", "public_origin", "enforce"}
    if args.kwarg is None and not needed <= names:
        raise InstallError("configure() не принимает обязательные именованные параметры адаптера.")


def _atomic_write(path: Path, data: bytes) -> None:
    fd, temporary = tempfile.mkstemp(prefix=path.name + ".account-access-", suffix=".tmp", dir=path.parent)
    try:
        if hasattr(os, "fchmod"):
            os.fchmod(fd, path.stat().st_mode & 0o777 if path.exists() else 0o644)
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def _snapshot(target: Path, names: list[str]) -> dict[str, bytes | None]:
    result = {}
    for name in names:
        path = target / name
        if path.is_symlink():
            raise InstallError(f"{name}: символическая ссылка не поддерживается установщиком.")
        if path.exists() and not path.is_file():
            raise InstallError(f"{name}: ожидался файл.")
        result[name] = path.read_bytes() if path.is_file() else None
    return result


def _write_changes(target: Path, changes: dict[str, bytes | None], previous: dict[str, bytes | None]) -> None:
    changed = []
    try:
        for name, data in changes.items():
            changed.append(name)
            if data is None:
                (target / name).unlink(missing_ok=True)
            else:
                _atomic_write(target / name, data)
    except Exception as error:
        failures = []
        for name in reversed(changed):
            try:
                if previous[name] is None:
                    (target / name).unlink(missing_ok=True)
                else:
                    _atomic_write(target / name, previous[name])
            except Exception:
                failures.append(name)
        extra = " Не удалось автоматически восстановить: " + ", ".join(failures) if failures else " Изменённые файлы восстановлены."
        raise InstallError("Установка/восстановление не завершено." + extra) from error


def install(target: str | Path, adapter: str | Path, *, check: bool = False,
            source_dir: str | Path | None = None) -> dict[str, Any]:
    target = Path(target).resolve()
    source_dir = Path(source_dir).resolve() if source_dir else Path(__file__).resolve().parent
    app = target / "app.py"
    if not app.is_file() or app.is_symlink():
        raise InstallError("Не найден обычный файл app.py в --target.")
    original = app.read_bytes()
    changed = patch(_text(original, "app.py")).encode("utf-8")
    if original.startswith(b"\xef\xbb\xbf"):
        changed = b"\xef\xbb\xbf" + changed
    adapter_path = Path(adapter).resolve()
    if not adapter_path.is_file():
        raise InstallError("Не найден файл --adapter с настроенной интеграцией.")
    adapter_data = adapter_path.read_bytes()
    validate_adapter(adapter_data)
    payload = {}
    for name in REQUIRED_MODULES:
        file = source_dir / name
        if not file.is_file():
            raise InstallError(f"Неполный пакет: отсутствует {name}.")
        data = file.read_bytes()
        source = _text(data, name)
        if name.endswith(".py"):
            _parse(source, name)
        payload[name] = data
    for name in OPTIONAL_MODULES:
        if (source_dir / name).is_file():
            payload[name] = (source_dir / name).read_bytes()
    payload[ADAPTER_NAME] = adapter_data
    payload["app.py"] = changed
    previous = _snapshot(target, list(payload))
    if previous["app.py"] != original:
        raise InstallError("app.py изменился во время проверки. Повторите установку при остановленном сервере.")
    changes = {name: data for name, data in payload.items() if data != previous[name]}
    summary = {
        "compatible": True,
        "status": "up_to_date" if not changes else "changes_required" if check else "installed",
        "changed_files": list(changes),
        "target": str(target),
        "check_only": check,
        "database_modified": False,
        "restart_required": bool(changes) and not check,
        "backup": None,
        "integration_note": "Статический контроль не заменяет проверку session_key, Premium и CSRF на копии действующего сервера.",
    }
    if check or not changes:
        return summary
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ") + "-" + secrets.token_hex(3)
    if (target / "backups").is_symlink():
        raise InstallError("Каталог backups не должен быть символической ссылкой.")
    backup = target / "backups" / ("account-access-" + stamp)
    backup.mkdir(parents=True, exist_ok=False)
    entries = {}
    for name in changes:
        before = previous[name]
        if before is not None:
            (backup / name).write_bytes(before)
        entries[name] = {
            "existed": before is not None,
            "before_sha256": _sha(before) if before is not None else None,
            "installed_sha256": _sha(changes[name]),
        }
    manifest = {"schema_version": 1, "created_at": datetime.now(timezone.utc).isoformat(),
                "target": str(target), "files": entries, "database_modified": False}
    (backup / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    try:
        _write_changes(target, changes, previous)
    except InstallError as error:
        raise InstallError(str(error) + " Резервная копия: " + str(backup)) from error
    summary["backup"] = str(backup)
    return summary


def restore(target: str | Path, backup: str | Path) -> dict[str, Any]:
    target = Path(target).resolve()
    backup = Path(backup).resolve()
    try:
        manifest = json.loads((backup / "manifest.json").read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise InstallError("Не удалось прочитать manifest.json резервной копии.") from error
    if manifest.get("schema_version") != 1 or Path(manifest.get("target", "")).resolve() != target:
        raise InstallError("Резервная копия относится к другому каталогу или формату.")
    entries = manifest.get("files")
    if not isinstance(entries, dict) or not entries or not set(entries) <= ALLOWED_FILES:
        raise InstallError("Некорректный список файлов резервной копии.")
    recovered = {}
    for name, entry in entries.items():
        if not isinstance(entry, dict) or type(entry.get("existed")) is not bool:
            raise InstallError("Некорректная запись manifest.json.")
        if entry["existed"]:
            file = backup / name
            if not file.is_file() or file.is_symlink():
                raise InstallError("Повреждена резервная копия: " + name)
            data = file.read_bytes()
            if _sha(data) != entry.get("before_sha256"):
                raise InstallError("Контрольная сумма резервной копии не совпадает: " + name)
            recovered[name] = data
        else:
            recovered[name] = None
    previous = _snapshot(target, list(recovered))
    _write_changes(target, recovered, previous)
    return {"status": "restored", "target": str(target), "backup": str(backup),
            "restored_files": list(recovered), "database_modified": False, "restart_required": True}


def main() -> int:
    parser = argparse.ArgumentParser(description="Подготовка безопасной интеграции Nightwell account-access")
    parser.add_argument("--target", required=True, help="Каталог с существующим app.py")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="Проверить совместимость без записи")
    mode.add_argument("--restore", metavar="BACKUP", help="Восстановить файлы из указанной резервной копии")
    parser.add_argument("--adapter", help="Настроенный файл account_access_host.py с ADAPTER_CONFIGURED=True")
    args = parser.parse_args()
    if not args.restore and not args.adapter:
        parser.error("для установки и --check требуется --adapter")
    try:
        result = restore(args.target, args.restore) if args.restore else install(args.target, args.adapter, check=args.check)
    except (InstallError, OSError) as error:
        print(str(error), file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
