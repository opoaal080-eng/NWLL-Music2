"""Install the additive Audius source and recommendation upgrade into the current Nightwell app.

Backs up app.py and four Python modules. Never copies a server,
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

BEGIN = '# NIGHTWELL_AUDIUS_V1_BEGIN'
END = '# NIGHTWELL_AUDIUS_V1_END'
FILES = ('audius_provider.py', 'audius_catalog.py', 'adaptive_wave.py', 'wave_ranker.py')
KNOWN_WAVE = {
    'adaptive_wave.py': {'2c19c64e61d778cad03c93980b3125e04ace4bc5d542833909a42455f34c0666'},
    'wave_ranker.py': {'2bfd16804d79bb6e56d49642100fac43e6dd0569c4b6c4c9d34e852ff28b8b68'},
}
HOOK = """
# NIGHTWELL_AUDIUS_V1_BEGIN
from pathlib import Path as _NWAudiusPath
from audius_catalog import install as _nw_install_audius
_nw_install_audius(globals())
from adaptive_wave import install as _nw_install_audius_wave
_nw_install_audius_wave(
    app, core, session, public,
    scheduler=globals().get('schedule_discovery'),
    hidden_preferences=(lambda uid: sync_preferences(uid, core.db)) if 'sync_preferences' in globals() else None,
    artist_preferences_path=_NWAudiusPath(__file__).resolve().with_name('nightwell_artist_preferences.sqlite3'))
# NIGHTWELL_AUDIUS_V1_END
"""


def patch(text):
    tree = ast.parse(text, 'app.py')
    functions = {node.name: node for node in tree.body if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))}
    imports_core = any(isinstance(node, ast.Import) and any(alias.name == 'server' and alias.asname == 'core' for alias in node.names) for node in tree.body)
    required = {'session', 'public', 'tracks', 'track', 'stream', 'cover', 'listening', 'recommendations'}
    if not imports_core or not required <= functions.keys():
        raise ValueError('app.py не распознан как совместимый сервер Nightwell Music. Файлы не изменены.')
    session = functions['session']
    if len(session.args.args) < 2 or session.args.args[1].arg != 'required':
        raise ValueError('Не найдена совместимая авторизация session(request, required=True).')
    if '/api/tracks' not in text or '/api/stream/{tid}' not in text:
        raise ValueError('Не найдены совместимые маршруты поиска и воспроизведения.')
    if text.count(BEGIN) != text.count(END) or text.count(BEGIN) > 1:
        raise ValueError('Повреждён блок предыдущей установки. Файлы не изменены.')
    # Public metadata must also work in modules holding the original callable.
    node = functions['public']
    class Sources(ast.NodeTransformer):
        def visit_Compare(self, value):
            self.generic_visit(value)
            if (len(value.ops) == 1 and isinstance(value.ops[0], ast.Eq)
                and isinstance(value.comparators[0], ast.Constant) and value.comparators[0].value == 'soundcloud'
                and ast.unparse(value.left) == "rights.get('source')"):
                value.ops = [ast.In()]
                value.comparators = [ast.Tuple(elts=[ast.Constant('soundcloud'), ast.Constant('audius')], ctx=ast.Load())]
            return value
    new_public = ast.unparse(Sources().visit(node))
    lines = text.splitlines(keepends=True)
    lines[node.lineno-1:node.end_lineno] = [new_public + '\n']
    text = ''.join(lines)
    if BEGIN in text:
        start = text.index(BEGIN)
        stop = text.index(END, start) + len(END)
        updated = text[:start] + HOOK.strip() + text[stop:]
    else:
        tree = ast.parse(text)
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
    if not (root / 'music_import.py').is_file():
        raise ValueError('Не найден music_import.py. Нужна действующая версия сервера с переносом плейлистов.')
    files = {'app.py': patch(app.read_text(encoding='utf-8-sig')).encode('utf-8')}
    for name in FILES:
        module = source / name
        if not module.is_file() and name in ('adaptive_wave.py', 'wave_ranker.py'):
            module = source.parent / 'adaptive-wave' / name
        data = module.read_bytes()
        ast.parse(data.decode('utf-8'), name)
        if (root / name).is_symlink():
            raise ValueError('Нельзя заменить ссылку ' + name)
        if name in KNOWN_WAVE and (root / name).is_file():
            previous = (root / name).read_text(encoding='utf-8-sig').encode('utf-8')
            if previous != data and digest(previous) not in KNOWN_WAVE[name]:
                raise ValueError('Найдена другая версия ' + name + '. Установка остановлена, чтобы сохранить новые изменения.')
        files[name] = data
    return root, files


def install(target, source=None, check=False):
    root, files = prepare(target, source)
    changed = [name for name, data in files.items() if not (root / name).is_file() or (root / name).read_bytes() != data]
    if check or not changed:
        return {'changed': changed, 'backup': None, 'checked': bool(check)}
    backup = root / 'backups' / ('audius-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
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
            temp = root / (name + '.nw-audius-new')
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
                print('Повтори поиск или перенос. В подборке нажми «Новая подборка».')
        return 0
    except (OSError, ValueError, SyntaxError) as error:
        print('Установка остановлена: ' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
