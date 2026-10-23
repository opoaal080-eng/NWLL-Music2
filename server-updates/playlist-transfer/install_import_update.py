"""Install only the playlist transfer module, with backup and no app.py replacement."""
import argparse
import datetime
from pathlib import Path
import py_compile
import shutil
import os

parser=argparse.ArgumentParser()
parser.add_argument('--target',default='.',help='Nightwell server folder')
args=parser.parse_args()
root=Path(args.target).resolve()
if not (root/'app.py').is_file() or not (root/'music_import_sources.py').is_file():
    raise SystemExit('Укажите папку сервера с app.py и music_import_sources.py через --target')
source=Path(__file__).with_name('music_import.py')
py_compile.compile(str(source),doraise=True)
backup=root/'backups'/('playlist-import-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
backup.mkdir(parents=True)
destination=root/'music_import.py'
if destination.exists():shutil.copy2(destination,backup/destination.name)
temporary=root/'music_import.py.new'
shutil.copy2(source,temporary)
os.replace(temporary,destination)
print('Обновлено:',destination)
print('Резервная копия:',backup)
print('Перезапустите сервер обычным способом. Настройки, аккаунты и плейлисты не изменены.')
