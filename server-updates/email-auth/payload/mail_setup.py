"""Run locally on the Windows server. Secrets are encrypted for the Windows user."""
import ctypes, getpass, json, os
from pathlib import Path


def _dpapi(data,decrypt=False):
    if os.name!='nt':raise RuntimeError('Use environment variables for SMTP on non-Windows systems')
    from ctypes import wintypes
    class Blob(ctypes.Structure):
        _fields_=[('size',wintypes.DWORD),('data',ctypes.POINTER(ctypes.c_ubyte))]
    buf=ctypes.create_string_buffer(data)
    incoming=Blob(len(data),ctypes.cast(buf,ctypes.POINTER(ctypes.c_ubyte)))
    outgoing=Blob()
    crypt=ctypes.WinDLL('crypt32',use_last_error=True)
    kernel=ctypes.WinDLL('kernel32',use_last_error=True)
    kernel.LocalFree.argtypes=[ctypes.c_void_p];kernel.LocalFree.restype=ctypes.c_void_p
    if decrypt:
        fn=crypt.CryptUnprotectData
        fn.argtypes=[ctypes.POINTER(Blob),ctypes.c_void_p,ctypes.c_void_p,ctypes.c_void_p,ctypes.c_void_p,wintypes.DWORD,ctypes.POINTER(Blob)]
        ok=fn(ctypes.byref(incoming),None,None,None,None,1,ctypes.byref(outgoing))
    else:
        fn=crypt.CryptProtectData
        fn.argtypes=[ctypes.POINTER(Blob),wintypes.LPCWSTR,ctypes.c_void_p,ctypes.c_void_p,ctypes.c_void_p,wintypes.DWORD,ctypes.POINTER(Blob)]
        ok=fn(ctypes.byref(incoming),'Nightwell SMTP',None,None,None,1,ctypes.byref(outgoing))
    if not ok:raise ctypes.WinError(ctypes.get_last_error())
    try:return ctypes.string_at(outgoing.data,outgoing.size)
    finally:kernel.LocalFree(ctypes.cast(outgoing.data,ctypes.c_void_p))


def unprotect(data):return _dpapi(data,True)


def main():
    if os.name!='nt':raise SystemExit('Set NW_SMTP_HOST/PORT/USER/PASSWORD/FROM/SECURITY in your service environment.')
    print('Nightwell: настройка отправки кодов. Ящик @nightwell.fun уже должен быть создан.')
    print('Пароль вводится только здесь, в чат его отправлять не нужно.')
    host=input('SMTP-сервер: ').strip()
    sender=input('Адрес отправителя, например noreply@nightwell.fun: ').strip()
    username=input('SMTP-логин [тот же адрес]: ').strip() or sender
    security=input('Защита ssl или starttls [ssl]: ').strip().lower() or 'ssl'
    if security not in ('ssl','starttls'):raise SystemExit('Разрешены только ssl или starttls')
    port=int(input('Порт [465 для ssl, 587 для starttls]: ').strip() or (465 if security=='ssl' else 587))
    password=getpass.getpass('SMTP-пароль или пароль приложения: ')
    if not host or not sender or '@' not in sender or not password:raise SystemExit('Не все поля заполнены')
    cfg={'host':host,'port':str(port),'user':username,'password':password,'from':sender,'security':security}
    path=Path('data/nightwell-mail.dpapi');path.parent.mkdir(parents=True,exist_ok=True)
    temporary=path.with_suffix('.tmp');temporary.write_bytes(_dpapi(json.dumps(cfg).encode()));os.replace(temporary,path)
    print('Настройки сохранены с шифрованием Windows. Следующий шаг: проверить доставку.')
    if input('Отправить тестовый код на этот ящик? [да/нет]: ').strip().lower() in ('да','yes','y'):
        from email_auth import send_code
        try:send_code(sender,'123456','register')
        except Exception:raise SystemExit('Письмо не отправлено. Подтверждение кодами не включено. Проверь SMTP-настройки.')
        print('Письмо принято SMTP-сервером. Проверь входящие и спам.')
    if input('Тестовое письмо получено, включить коды при входе и регистрации? [да/нет]: ').strip().lower() in ('да','yes','y'):
        import winreg
        with winreg.CreateKey(winreg.HKEY_CURRENT_USER,'Environment') as key:
            winreg.SetValueEx(key,'NW_EMAIL_CODES_ENABLED',0,winreg.REG_SZ,'1')
        print('Коды включены. Перезапусти Nightwell своим обычным батником.')
    else:print('Коды пока выключены, текущий вход продолжит работать.')

if __name__=='__main__':main()
