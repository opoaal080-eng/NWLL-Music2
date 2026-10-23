"""Password + emailed one-time code for Nightwell. No sessions before verification."""
import hashlib, hmac, json, os, secrets, smtplib, sqlite3, ssl, time
from email.message import EmailMessage
from pathlib import Path
from fastapi import HTTPException, Request
from fastapi.responses import JSONResponse, FileResponse
from starlette.concurrency import run_in_threadpool

TTL=600
COOLDOWN=60
MAX_TRIES=5


def mail_settings():
    # Passwords belong on the server. Never accept an SMTP server or credentials from HTTP.
    names=('HOST','PORT','USER','PASSWORD','FROM','SECURITY')
    cfg={k.lower():os.environ.get('NW_SMTP_'+k,'') for k in names}
    protected=Path('data/nightwell-mail.dpapi')
    if os.name=='nt' and protected.is_file():
        from mail_setup import unprotect
        saved=json.loads(unprotect(protected.read_bytes()).decode())
        cfg={k:cfg.get(k) or v for k,v in saved.items()}
    if not all(cfg.get(k) for k in ('host','user','password','from')):
        raise HTTPException(503,'Отправка кодов ещё не настроена на сервере')
    if cfg.get('security') not in ('ssl','starttls'):
        raise HTTPException(503,'Для отправки кодов требуется защищённый SMTP')
    if any('\r' in cfg[k] or '\n' in cfg[k] for k in ('host','user','from')):
        raise HTTPException(503,'Некорректные SMTP-настройки')
    try:cfg['port']=int(cfg.get('port') or (465 if cfg['security']=='ssl' else 587))
    except ValueError:raise HTTPException(503,'Некорректный порт SMTP')
    return cfg


def send_code(email,code,action):
    cfg=mail_settings()
    message=EmailMessage()
    message['From']=cfg['from'];message['To']=email
    message['Subject']='Код подтверждения Nightwell Music'
    purpose='регистрации' if action=='register' else 'входа'
    message.set_content(f'Код для {purpose} в Nightwell Music: {code}\n\nКод действует 10 минут и используется один раз. Никому его не сообщайте.\nЕсли вы не запрашивали код, проигнорируйте письмо.')
    context=ssl.create_default_context()
    try:
        if cfg['security']=='ssl':
            with smtplib.SMTP_SSL(cfg['host'],cfg['port'],timeout=15,context=context) as smtp:
                smtp.login(cfg['user'],cfg['password']);smtp.send_message(message)
        else:
            with smtplib.SMTP(cfg['host'],cfg['port'],timeout=15) as smtp:
                smtp.ehlo();smtp.starttls(context=context);smtp.ehlo()
                smtp.login(cfg['user'],cfg['password']);smtp.send_message(message)
    except (OSError,smtplib.SMTPException):
        # Do not log SMTP responses: they can contain credentials, recipients or message bodies.
        raise HTTPException(503,'Не удалось отправить код. Попробуйте позже') from None


def validate_address(value):
    from email_validator import validate_email, EmailNotValidError, caching_resolver
    if not isinstance(value,str) or len(value)>254:
        raise HTTPException(400,'Укажите действующий email')
    # Match Nightwell's existing case-insensitive account lookup.
    address=value.strip().casefold()
    try:
        result=validate_email(address,allow_smtputf8=False,check_deliverability=True,
                              dns_resolver=caching_resolver(timeout=3))
    except EmailNotValidError:
        raise HTTPException(400,'Проверьте email: адрес или почтовый домен некорректен') from None
    # An inconclusive DNS lookup is not proof that an address is invalid.
    if not getattr(result,'mx',None):
        raise HTTPException(503,'Не удалось проверить почтовый домен. Попробуйте позже')
    return address


def _secret(path):
    path=Path(path);path.parent.mkdir(parents=True,exist_ok=True)
    try:
        fd=os.open(path,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600)
    except FileExistsError:
        value=path.read_bytes()
    else:
        value=secrets.token_bytes(32)
        with os.fdopen(fd,'wb') as out:out.write(value)
    if len(value)!=32:raise RuntimeError('Invalid email authentication secret')
    return value


class EmailAuth:
    def __init__(self,core,*,mode='local',registration='open',sender=send_code,
                 validator=validate_address,secret_path='data/email_auth.key',clock=time.time):
        self.core=core;self.mode=mode;self.registration=registration
        self.sender=sender;self.validator=validator;self.clock=clock
        self.secret=_secret(secret_path)

    def init(self):
        with self.core.db() as db:
            db.execute('''CREATE TABLE IF NOT EXISTS email_auth_challenges(
                id TEXT PRIMARY KEY, action TEXT NOT NULL, email TEXT NOT NULL,
                user_id TEXT, password_hash TEXT NOT NULL, digest TEXT NOT NULL,
                created REAL NOT NULL, expires REAL NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
                state TEXT NOT NULL, ip TEXT NOT NULL)''')
            db.execute('CREATE INDEX IF NOT EXISTS email_challenge_recipient ON email_auth_challenges(email,created)')
            db.execute('CREATE INDEX IF NOT EXISTS email_challenge_ip ON email_auth_challenges(ip,created)')
            db.execute('CREATE TABLE IF NOT EXISTS email_auth_attempts(ip TEXT NOT NULL,created REAL NOT NULL)')
            db.execute('CREATE INDEX IF NOT EXISTS email_auth_attempt_ip ON email_auth_attempts(ip,created)')

    def digest(self,ident,code):
        return hmac.new(self.secret,(ident+'\0'+code).encode(),hashlib.sha256).hexdigest()

    def rate(self,ip):
        now=self.clock()
        with self.core.db() as db:
            db.execute('BEGIN IMMEDIATE')
            db.execute('DELETE FROM email_auth_attempts WHERE created<?',(now-3600,))
            count=db.execute('SELECT COUNT(*) FROM email_auth_attempts WHERE ip=? AND created>?',(ip,now-60)).fetchone()[0]
            if count>=12:raise HTTPException(429,'Слишком много попыток. Подождите минуту')
            db.execute('INSERT INTO email_auth_attempts VALUES(?,?)',(ip,now))
            db.execute('DELETE FROM email_auth_challenges WHERE expires<?',(now-86400,))

    @staticmethod
    def challenge(row):
        local,domain=row['email'].split('@',1)
        return {'verification_required':True,'challenge':{
            'id':row['id'],'action':row['action'],'email_hint':local[:1]+'***@'+domain,
            'expires_at':row['expires'],'resend_at':row['created']+COOLDOWN}}

    def start(self,action,ip,body):
        self.init();self.rate(ip)
        if action not in ('register','login'):raise HTTPException(404,'Маршрут не найден')
        if action=='register' and self.registration=='closed':raise HTTPException(403,'Регистрация закрыта')
        if body.get('challenge_id'):
            if body.get('resend') is True:return self.resend(action,ip,body['challenge_id'])
            return self.verify(action,body['challenge_id'],body.get('code'))
        if body.get('supports_email_codes') is not True:
            raise HTTPException(426,'Обновите приложение для входа с кодом из письма или войдите на сайте')
        email=self.validator(body.get('email'));password=body.get('password')
        if not isinstance(password,str) or not 10<=len(password)<=128:
            raise HTTPException(400,'Введите пароль от 10 до 128 символов')
        with self.core.db() as db:
            user=db.execute('SELECT * FROM users WHERE email=?',(email,)).fetchone()
        if action=='register':
            if user:raise HTTPException(409,'Невозможно создать аккаунт с этими данными')
            uid=None;password_hash=self.core.password_hash(password)
        else:
            ok=self.core.verify(password,user['password'] if user else self.core.DUMMY_PASSWORD)
            if not user or not ok:raise HTTPException(401,'Неверный email или пароль')
            uid=user['id'];password_hash=user['password']
        return self.issue(action,email,uid,password_hash,ip)

    def issue(self,action,email,uid,password_hash,ip,previous=None):
        now=self.clock();ident=secrets.token_urlsafe(32);code=f'{secrets.randbelow(1000000):06d}'
        # Reserve and throttle before sending. SMTP runs outside SQLite transactions.
        with self.core.db() as db:
            db.execute('BEGIN IMMEDIATE')
            recent=db.execute('SELECT MAX(created) FROM email_auth_challenges WHERE email=?',(email,)).fetchone()[0]
            if recent is not None and now-recent<COOLDOWN:
                raise HTTPException(429,'Повторный код можно запросить через минуту')
            count=db.execute('SELECT COUNT(*) FROM email_auth_challenges WHERE email=? AND created>?',(email,now-3600)).fetchone()[0]
            ip_count=db.execute('SELECT COUNT(*) FROM email_auth_challenges WHERE ip=? AND created>?',(ip,now-3600)).fetchone()[0]
            if count>=5 or ip_count>=20:raise HTTPException(429,'Лимит отправки кодов исчерпан. Попробуйте через час')
            if previous:
                row=db.execute('SELECT * FROM email_auth_challenges WHERE id=?',(previous,)).fetchone()
                if not row or row['state']!='ready' or row['expires']<=now or row['attempts']>=MAX_TRIES:
                    raise HTTPException(400,'Код истёк. Начните вход заново')
                db.execute('UPDATE email_auth_challenges SET state="superseded" WHERE id=?',(previous,))
            db.execute('INSERT INTO email_auth_challenges(id,action,email,user_id,password_hash,digest,created,expires,state,ip) VALUES(?,?,?,?,?,?,?,?,?,?)',
                (ident,action,email,uid,password_hash,self.digest(ident,code),now,now+TTL,'sending',ip))
        try:self.sender(email,code,action)
        except Exception:
            with self.core.db() as db:db.execute('UPDATE email_auth_challenges SET state="failed" WHERE id=?',(ident,))
            raise HTTPException(503,'Не удалось отправить код. Попробуйте позже') from None
        with self.core.db() as db:
            db.execute('UPDATE email_auth_challenges SET state="ready" WHERE id=?',(ident,))
            row=db.execute('SELECT * FROM email_auth_challenges WHERE id=?',(ident,)).fetchone()
        return self.challenge(row)

    def resend(self,action,ip,ident):
        if not isinstance(ident,str) or len(ident)>100:raise HTTPException(400,'Начните вход заново')
        with self.core.db() as db:
            row=db.execute('SELECT * FROM email_auth_challenges WHERE id=? AND action=?',(ident,action)).fetchone()
        if not row or row['state']!='ready' or row['expires']<=self.clock() or row['attempts']>=MAX_TRIES:
            raise HTTPException(400,'Код истёк. Начните вход заново')
        return self.issue(action,row['email'],row['user_id'],row['password_hash'],ip,previous=ident)

    def verify(self,action,ident,code):
        if not isinstance(ident,str) or len(ident)>100 or not isinstance(code,str) or len(code)!=6 or not code.isascii() or not code.isdecimal():
            raise HTTPException(400,'Введите шестизначный код из письма')
        now=self.clock();failure=None;identity=None;token=None
        with self.core.db() as db:
            db.execute('BEGIN IMMEDIATE')
            row=db.execute('SELECT * FROM email_auth_challenges WHERE id=? AND action=?',(ident,action)).fetchone()
            if not row or row['state']!='ready' or row['expires']<=now:
                failure=(400,'Код истёк или уже использован. Начните вход заново')
            elif row['attempts']>=MAX_TRIES:
                failure=(429,'Слишком много неверных кодов. Начните вход заново')
            elif not hmac.compare_digest(row['digest'],self.digest(ident,code)):
                db.execute('UPDATE email_auth_challenges SET attempts=attempts+1 WHERE id=?',(ident,))
                failure=(400,'Неверный код')
            else:
                if action=='register':
                    if self.registration=='closed':failure=(403,'Регистрация закрыта')
                    elif db.execute('SELECT 1 FROM users WHERE email=?',(row['email'],)).fetchone():failure=(409,'Невозможно создать аккаунт с этими данными')
                    else:
                        uid=secrets.token_hex(16)
                        db.execute('INSERT INTO users(id,email,password,is_admin) VALUES(?,?,?,0)',(uid,row['email'],row['password_hash']))
                        admin=False
                else:
                    user=db.execute('SELECT * FROM users WHERE id=? AND email=?',(row['user_id'],row['email'])).fetchone()
                    if not user or not hmac.compare_digest(str(user['password']),str(row['password_hash'])):
                        failure=(401,'Данные аккаунта изменились. Начните вход заново')
                    else:uid=user['id'];admin=bool(user['is_admin'])
                if not failure:
                    token=secrets.token_urlsafe(32);csrf=secrets.token_urlsafe(32)
                    db.execute('DELETE FROM sessions WHERE expires<=?',(int(now),))
                    db.execute('INSERT INTO sessions(token,user_id,csrf,expires) VALUES(?,?,?,?)',
                        (hashlib.sha256(token.encode()).hexdigest(),uid,csrf,int(now)+604800))
                    db.execute('UPDATE email_auth_challenges SET state="used" WHERE id=?',(ident,))
                    db.execute('UPDATE email_auth_challenges SET state="superseded" WHERE email=? AND id!=? AND state="ready"',(row['email'],ident))
                    identity={'user':{'id':uid,'email':row['email'],'is_admin':admin},'csrf':csrf}
        # Raise after commit so failed-code attempt counters persist.
        if failure:raise HTTPException(*failure)
        response=JSONResponse(identity,headers={'Cache-Control':'no-store'})
        secure=self.mode=='pilot' or os.environ.get('NW_ORIGIN','').startswith('https://')
        response.set_cookie('nw_session',token,max_age=604800,httponly=True,secure=secure,samesite='strict',path='/')
        return response


def install(app,core,mode='local',registration='open'):
    if not getattr(app.state,'nightwell_email_script',False):
        app.state.nightwell_email_script=True
        count=len(app.router.routes)
        @app.get('/auth-email.js')
        def email_auth_script():
            return FileResponse(Path(__file__).parent/'web'/'auth-email.js',media_type='application/javascript',headers={'Cache-Control':'no-cache'})
        app.router.routes[:]=app.router.routes[count:]+app.router.routes[:count]
    # Enable only after the operator has configured a sender and installed updated clients.
    enabled=os.environ.get('NW_EMAIL_CODES_ENABLED')
    if enabled is None and os.name=='nt':
        try:
            import winreg
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER,'Environment') as key:
                enabled=winreg.QueryValueEx(key,'NW_EMAIL_CODES_ENABLED')[0]
        except OSError:pass
    if enabled!='1':return
    if getattr(app.state,'nightwell_email_auth',False):return
    app.state.nightwell_email_auth=True
    service=EmailAuth(core,mode=mode,registration=registration)
    app.state.email_auth=service
    app.router.routes[:]=[r for r in app.router.routes if getattr(r,'path','') not in ('/api/register','/api/login')]
    count=len(app.router.routes)
    @app.post('/api/register')
    @app.post('/api/login')
    async def authenticate(request:Request):
        try:body=await request.json()
        except (ValueError,UnicodeError):raise HTTPException(400,'Некорректный JSON')
        if not isinstance(body,dict):raise HTTPException(400,'Некорректный JSON')
        ip=request.headers.get('x-nw-client-ip','') if mode=='pilot' else (request.client.host if request.client else 'unknown')
        result=await run_in_threadpool(service.start,request.url.path.rsplit('/',1)[-1],ip,body)
        return JSONResponse(result,status_code=202,headers={'Cache-Control':'no-store'}) if isinstance(result,dict) else result
    app.router.routes[:]=app.router.routes[count:]+app.router.routes[:count]
