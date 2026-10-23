import contextlib, hashlib, json, os, sqlite3, sys, tempfile, unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).parent/'payload'))
import email_auth as m
from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient

class Core:
    DUMMY_PASSWORD='hash:dummy'
    def __init__(self,path):
        self.path=path
        with self.db() as db:
            db.executescript('CREATE TABLE users(id TEXT PRIMARY KEY,email TEXT UNIQUE,password TEXT,is_admin INTEGER DEFAULT 0);CREATE TABLE sessions(token TEXT PRIMARY KEY,user_id TEXT,csrf TEXT,expires INTEGER);')
    @contextlib.contextmanager
    def db(self):
        db=sqlite3.connect(self.path);db.row_factory=sqlite3.Row
        try:
            with db:yield db
        finally:db.close()
    @staticmethod
    def password_hash(p):return 'hash:'+p
    @staticmethod
    def verify(p,h):return h=='hash:'+p

class AuthTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.core=Core(str(Path(self.tmp.name)/'db'));self.now=1000;self.mail=[]
        self.service=m.EmailAuth(self.core,mode='pilot',sender=lambda *a:self.mail.append(a),validator=lambda e:e.strip().casefold(),secret_path=Path(self.tmp.name)/'key',clock=lambda:self.now)
        self.service.init()
    def start(self,action='register',**kw):
        return self.service.start(action,'ip',dict(email='user@gmail.com',password='longpassword',supports_email_codes=True,**kw))['challenge']['id']
    def confirm(self,ident,code=None,action='register'):
        return self.service.start(action,'ip',{'challenge_id':ident,'code':code or self.mail[-1][1]})
    def count(self,table):
        with self.core.db() as db:return db.execute('SELECT COUNT(*) FROM '+table).fetchone()[0]
    def fail(self,status,fn,*a,**kw):
        with self.assertRaises(HTTPException) as cm:fn(*a,**kw)
        self.assertEqual(cm.exception.status_code,status)
    def user(self):
        with self.core.db() as db:db.execute('INSERT INTO users VALUES(?,?,?,?)',('u','user@gmail.com','hash:longpassword',1))
    def test_registration_and_replay(self):
        ident=self.start();self.assertEqual(self.count('users'),0);self.assertEqual(self.count('sessions'),0)
        result=self.confirm(ident);self.assertEqual(self.count('users'),1);self.assertEqual(self.count('sessions'),1)
        self.assertIn('Secure',result.headers['set-cookie']);self.assertIn('HttpOnly',result.headers['set-cookie'])
        self.assertFalse(json.loads(result.body)['user']['is_admin'])
        self.fail(400,self.confirm,ident);self.assertEqual(self.count('sessions'),1)
    def test_no_plaintext_code(self):
        ident=self.start()
        with self.core.db() as db:row=dict(db.execute('SELECT * FROM email_auth_challenges').fetchone())
        self.assertNotEqual(row['digest'],self.mail[-1][1]);self.assertNotEqual(row['password_hash'],'longpassword')
    def test_wrong_codes_persist_and_lock(self):
        ident=self.start();wrong='111111' if self.mail[-1][1]!='111111' else '222222'
        for _ in range(5):self.fail(400,self.confirm,ident,wrong)
        self.fail(429,self.confirm,ident);self.assertEqual(self.count('users'),0)
    def test_expiry(self):
        ident=self.start();self.now+=600;self.fail(400,self.confirm,ident)
    def test_resend_cooldown_and_old_invalid(self):
        ident=self.start();self.fail(429,self.service.resend,'register','ip',ident)
        self.now+=61;new=self.service.resend('register','ip',ident)['challenge']['id']
        self.fail(400,self.confirm,ident);self.confirm(new)
    def test_hourly_email_limit(self):
        ident=self.start()
        for _ in range(4):
            self.now+=61;ident=self.service.resend('register','ip',ident)['challenge']['id']
        self.now+=61;self.fail(429,self.service.resend,'register','ip',ident)
    def test_bad_password_sends_no_email(self):
        self.user();self.fail(401,self.service.start,'login','ip',dict(email='user@gmail.com',password='wrongpassword',supports_email_codes=True));self.assertEqual(self.mail,[])
    def test_login_requires_code_and_keeps_admin(self):
        self.user();ident=self.start('login');self.assertEqual(self.count('sessions'),0)
        result=self.confirm(ident,action='login');self.assertTrue(json.loads(result.body)['user']['is_admin'])
    def test_changed_password_invalidates_pending_login(self):
        self.user();ident=self.start('login')
        with self.core.db() as db:db.execute('UPDATE users SET password=?',('changed',))
        self.fail(401,self.confirm,ident,action='login');self.assertEqual(self.count('sessions'),0)
    def test_smtp_failure_never_creates_user(self):
        self.service.sender=lambda *a:(_ for _ in ()).throw(RuntimeError('SMTP SECRET'))
        self.fail(503,self.start);self.assertEqual(self.count('users'),0);self.assertEqual(self.count('sessions'),0)
    def test_closed_and_legacy(self):
        self.service.registration='closed';self.fail(403,self.start)
        self.fail(426,self.service.start,'login','ip',{})
    def test_action_binding(self):
        ident=self.start();self.fail(400,self.confirm,ident,action='login')
    def test_ip_rate(self):
        for _ in range(12):self.service.rate('other')
        self.fail(429,self.service.rate,'other')
    def test_route_replacement_disabled_and_enabled(self):
        app=FastAPI()
        @app.post('/api/login')
        def old():return {'legacy':True}
        @app.get('/{asset}')
        def fallback(asset):return {'fallback':True}
        with patch.dict(os.environ,{'NW_EMAIL_CODES_ENABLED':'0'}):m.install(app,self.core)
        client=TestClient(app);self.assertTrue(client.post('/api/login').json()['legacy'])
        self.assertIn('use strict',client.get('/auth-email.js').text)
        with patch.dict(os.environ,{'NW_EMAIL_CODES_ENABLED':'1'}),patch.object(m,'EmailAuth',return_value=self.service):m.install(app,self.core)
        self.assertEqual(client.post('/api/login',json={}).status_code,426)
        self.assertEqual(client.post('/api/login',json=[]).status_code,400)
        reply=client.post('/api/register',json=dict(email='user@gmail.com',password='longpassword',supports_email_codes=True))
        self.assertEqual(reply.status_code,202);self.assertNotIn('set-cookie',reply.headers)
        result=client.post('/api/register',json={'challenge_id':reply.json()['challenge']['id'],'code':self.mail[-1][1]})
        self.assertEqual(result.status_code,200);self.assertIn('nw_session=',result.headers['set-cookie'])
    def test_validation_rejects_bad_address(self):
        for value in ['@gmail.com','user gmail.com',None]:self.fail(400,m.validate_address,value)
    def test_inconclusive_dns_is_retryable(self):
        from types import SimpleNamespace
        with patch('email_validator.validate_email',return_value=SimpleNamespace(mx=None)):
            self.fail(503,m.validate_address,'user@gmail.com')

if __name__=='__main__':unittest.main(verbosity=2)
