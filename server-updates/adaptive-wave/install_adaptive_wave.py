"""Install an additive recommendation upgrade into the current Nightwell app.

Backs up only app.py and the two new Python modules. Never copies a server,
configuration, accounts database, audio cache, payments or client UI.
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

BEGIN = '# NIGHTWELL_ADAPTIVE_WAVE_V3_BEGIN'
END = '# NIGHTWELL_ADAPTIVE_WAVE_V3_END'
FILES = ('adaptive_wave.py', 'wave_ranker.py')
HOOK = '''
# NIGHTWELL_ADAPTIVE_WAVE_V3_BEGIN
from pathlib import Path as _NWAdaptivePath
from adaptive_wave import install as _nw_install_adaptive_wave
_nw_install_adaptive_wave(
    app, core, session, public,
    scheduler=globals().get('schedule_discovery'),
    hidden_preferences=(lambda uid: sync_preferences(uid, core.db)) if 'sync_preferences' in globals() else None,
    artist_preferences_path=_NWAdaptivePath(__file__).resolve().with_name('nightwell_artist_preferences.sqlite3'))
# NIGHTWELL_ADAPTIVE_WAVE_V3_END
'''


def patch(text):
    tree = ast.parse(text, 'app.py')
    functions = {node.name for node in tree.body if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))}
    imports_core = any(isinstance(node, ast.Import) and any(alias.name == 'server' and alias.asname == 'core' for alias in node.names) for node in tree.body)
    session = next((node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == 'session'), None)
    if not imports_core or not {'session', 'public', 'recommendations', 'listening'} <= functions:
        raise ValueError('app.py не распознан как совместимый сервер Nightwell Music. Файлы не изменены.')
    if session is None or len(session.args.args) < 2 or session.args.args[1].arg != 'required':
        raise ValueError('Не найдена совместимая авторизация session(request, required=True).')
    if '/api/wave' not in text or '/api/listening' not in text:
        raise ValueError('В app.py не найдены текущая подборка и история прослушиваний.')
    if text.count(BEGIN) != text.count(END) or text.count(BEGIN) > 1:
        raise ValueError('Повреждён блок предыдущей установки. Файлы не изменены.')
    if BEGIN in text:
        start = text.index(BEGIN)
        stop = text.index(END, start) + len(END)
        updated = text[:start] + HOOK.strip() + text[stop:]
    else:
        main = next((node.lineno-1 for node in tree.body if isinstance(node, ast.If)
                     and isinstance(node.test, ast.Compare) and isinstance(node.test.left, ast.Name)
                     and node.test.left.id == '__name__'), None)
        lines = text.splitlines(keepends=True)
        offset = sum(map(len, lines[:main])) if main is not None else len(text)
        updated = text[:offset].rstrip() + '\n\n' + HOOK.strip() + '\n\n' + text[offset:]
    ast.parse(updated, 'app.py')
    return updated


def digest(data):
    return hashlib.sha256(data).hexdigest()


def prepare(target, source=None):
    root = Path(target).expanduser().resolve()
    source = Path(source or Path(__file__).parent).resolve()
    app = root / 'app.py'
    if not app.is_file() or app.is_symlink():
        raise ValueError('Не найден обычный app.py в папке: ' + str(root))
    if not (root / 'wave_preferences.py').is_file():
        raise ValueError('Не найден wave_preferences.py. Нужна действующая версия сервера с настройками подборки.')
    files = {'app.py': patch(app.read_text(encoding='utf-8-sig')).encode('utf-8')}
    for name in FILES:
        data = (source / name).read_bytes()
        ast.parse(data.decode('utf-8'), name)
        if (root / name).is_symlink():
            raise ValueError('Нельзя заменить ссылку ' + name)
        files[name] = data
    return root, files


def install(target, source=None, check=False):
    root, files = prepare(target, source)
    changed = [name for name, data in files.items() if not (root / name).is_file() or (root / name).read_bytes() != data]
    if check or not changed:
        return {'changed': changed, 'backup': None, 'checked': bool(check)}
    backup = root / 'backups' / ('adaptive-wave-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
    (backup / 'previous').mkdir(parents=True)
    entries = []
    for name in changed:
        previous = (root / name).is_file()
        if previous:
            shutil.copy2(root / name, backup / 'previous' / name)
        entries.append({'name': name, 'previous': previous, 'installed_sha256': digest(files[name])})
    (backup / 'manifest.json').write_text(json.dumps({'target': str(root), 'entries': entries}, ensure_ascii=False, indent=2), encoding='utf-8')
    completed = []
    try:
        # Install modules before the importing app file; rollback partial writes.
        for name in sorted(changed, key=lambda value: value == 'app.py'):
            temp = root / (name + '.nw-adaptive-new')
            try:
                temp.write_bytes(files[name])
                os.replace(temp, root / name)
                completed.append(name)
            finally:
                temp.unlink(missing_ok=True)
    except BaseException:
        for name in reversed(completed):
            previous = backup / 'previous' / name
            if previous.is_file():
                shutil.copy2(previous, root / name)
            else:
                (root / name).unlink(missing_ok=True)
        raise
    return {'changed': changed, 'backup': str(backup), 'checked': False}


def rollback(folder):
    folder = Path(folder).resolve()
    manifest = json.loads((folder / 'manifest.json').read_text(encoding='utf-8'))
    root = Path(manifest['target']).resolve()
    for entry in manifest['entries']:
        name = entry['name']
        if name not in ('app.py', *FILES):
            raise ValueError('Неожиданный файл в резервной копии')
        path = root / name
        if path.is_symlink() or not path.is_file() or digest(path.read_bytes()) != entry['installed_sha256']:
            raise ValueError('После установки файл был изменён: ' + name)
        if entry['previous'] and not (folder / 'previous' / name).is_file():
            raise ValueError('Не найдена предыдущая версия ' + name)
    for entry in manifest['entries']:
        name = entry['name']
        if entry['previous']:
            shutil.copy2(folder / 'previous' / name, root / name)
        else:
            (root / name).unlink()
    return root


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument('--target', default=r'C:\Nightwell Music\nightwell-music')
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--rollback')
    args = parser.parse_args(argv)
    try:
        if args.rollback:
            print('Откат выполнен:', rollback(args.rollback))
        else:
            result = install(args.target, check=args.check)
            print(json.dumps(result, ensure_ascii=False, indent=2))
            if not args.check:
                print('Готово. Перезапусти музыкальный сервер привычным батником.')
                print('В приложении нажми «Новая подборка».')
        return 0
    except (OSError, ValueError, SyntaxError) as error:
        print('Установка остановлена: ' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
