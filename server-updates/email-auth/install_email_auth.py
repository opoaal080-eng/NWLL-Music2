"""Install the email-code update with timestamped backups; does not enable SMTP."""
import argparse, ast, datetime, os, shutil
from pathlib import Path

HOOK='\n# Nightwell email verification\nfrom email_auth import install as install_email_auth\ninstall_email_auth(app, core, MODE, REGISTRATION)\n'
SCRIPT='<script defer src="/auth-email.js"></script>'

def install(target, payload=None):
    target=Path(target).resolve()
    payload=Path(payload) if payload else Path(__file__).parent/'payload'
    app=target/'app.py'; index=target/'web/index.html'
    if not app.is_file() or not index.is_file():
        raise RuntimeError('Выбери папку nightwell-music с app.py и web/index.html')
    source=app.read_text(encoding='utf-8-sig'); html=index.read_text(encoding='utf-8-sig')
    ast.parse(source)
    for name in ('MODE','REGISTRATION','core','app'):
        if name not in source:raise RuntimeError('Неизвестная версия app.py: '+name)
    if 'install_email_auth(app, core, MODE, REGISTRATION)' not in source:source+=HOOK
    if '/auth-email.js' not in html:
        if '</body>' not in html:raise RuntimeError('В index.html не найден </body>')
        html=html.replace('</body>',SCRIPT+'\n</body>',1)
    html=html.replace('Локальная версия для разработки. Используй тестовый email и отдельный пароль.','Используй свою действующую почту и отдельный пароль.')
    ast.parse(source)
    changes={'app.py':source.encode(),'web/index.html':html.encode()}
    for name in ('email_auth.py','mail_setup.py','web/auth-email.js'):
        data=(payload/name).read_bytes()
        if name.endswith('.py'):ast.parse(data.decode())
        changes[name]=data
    backup=target/'backups'/('email-auth-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
    backup.mkdir(parents=True)
    changed=[]
    try:
        for name,data in changes.items():
            path=target/name; old=backup/name
            if path.exists():old.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(path,old)
            path.parent.mkdir(parents=True,exist_ok=True)
            temporary=path.with_name(path.name+'.email-new');temporary.write_bytes(data)
            os.replace(temporary,path);changed.append(name)
    except Exception:
        for name in reversed(changed):
            path=target/name;old=backup/name
            if old.exists():shutil.copy2(old,path)
            else:path.unlink(missing_ok=True)
        raise
    return backup

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--target',default='.')
    args=parser.parse_args()
    print('Резервная копия:',install(args.target))
    print('Файлы обновлены. Коды не включены автоматически. Настрой отправку через mail_setup.py.')
