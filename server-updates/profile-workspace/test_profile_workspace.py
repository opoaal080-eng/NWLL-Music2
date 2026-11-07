import base64
import contextlib
import importlib.util
import io
import json
import sqlite3
from pathlib import Path
from types import SimpleNamespace

import httpx
import pytest
from fastapi import FastAPI
from PIL import Image

from profile_workspace import install
from install_profile_workspace import install as install_files, rollback


@pytest.fixture
def anyio_backend():
    return "asyncio"


@pytest.fixture
def service(tmp_path):
    @contextlib.contextmanager
    def db():
        connection = sqlite3.connect(tmp_path / "music.db")
        connection.row_factory = sqlite3.Row
        try:
            with connection:
                yield connection
        finally:
            connection.close()
    with db() as c:
        c.executescript("""CREATE TABLE playlists(id TEXT,user_id TEXT,name TEXT);
        CREATE TABLE playlist_tracks(playlist_id TEXT,track_id TEXT,position INTEGER);
        CREATE TABLE likes(user_id TEXT,track_id TEXT);
        CREATE TABLE tracks(id TEXT,title TEXT,artist TEXT,rights TEXT,file TEXT);
        INSERT INTO playlists VALUES('p1','alice','Мой плейлист');
        INSERT INTO playlist_tracks VALUES('p1','t1',0),('p1','t2',1),('p1','t3',2);
        INSERT INTO likes VALUES('alice','t1');""")
        for tid, rights in [('t1', {'status': 'approved', 'visibility': 'shared'}), ('t2', {'status': 'draft'}), ('t3', {'status': 'approved', 'visibility': 'private'})]:
            c.execute('INSERT INTO tracks VALUES(?,?,?,?,?)', (tid, '<script>alert(1)</script>', 'Artist', json.dumps(rights), '/private/audio.mp3'))
    app = FastAPI()
    def session(request, required=False):
        uid = request.headers.get('user')
        return {'user_id': uid} if uid else None
    install(app, SimpleNamespace(db=db, ROOT=tmp_path), session,
            lambda request: request.headers.get('x-csrf-token') == 'valid', lambda row: dict(row))
    return app, db


@pytest.mark.anyio
async def test_profile_auth_isolation_validation_and_avatar(service):
    app, db = service
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app), base_url='http://test') as c:
        assert (await c.get('/api/profile')).status_code == 401
        assert (await c.put('/api/profile', headers={'user':'alice'}, json={'nickname':'Mike'})).status_code == 403
        headers={'user':'alice','x-csrf-token':'valid'}
        for name in ['', 'A', 'x'*41, 'a\x00b', 'a\u202eb']:
            assert (await c.put('/api/profile',headers=headers,json={'nickname':name})).status_code == 400
        assert (await c.put('/api/profile', headers=headers, json={'nickname':'  Михаил  ','user_id':'bob'})).json()['nickname'] == 'Михаил'
        assert (await c.get('/api/profile',headers={'user':'bob'})).json()['nickname'] == ''
        buffer=io.BytesIO();Image.new('RGB',(800,600),'red').save(buffer,'PNG')
        response=await c.post('/api/profile/avatar',headers=headers,json={'image':base64.b64encode(buffer.getvalue()).decode()})
        assert response.status_code == 200
        url=response.json()['avatar_url']
        image=await c.get(url,headers=headers)
        assert image.status_code == 200 and image.headers['content-type']=='image/jpeg'
        assert Image.open(io.BytesIO(image.content)).size == (512,512)
        assert (await c.get(url,headers={'user':'bob'})).status_code == 404
        assert (await c.post('/api/profile/avatar',headers=headers,json={'image':base64.b64encode(b'<svg/>').decode()})).status_code == 400
        assert (await c.post('/api/profile/avatar',headers=headers,json={'image':'x'*4_200_000})).status_code == 413
        assert (await c.delete('/api/profile/avatar',headers=headers)).json()['avatar_url']==''
        assert (await c.get(url,headers=headers)).status_code==404
        assert (await c.get('/api/profile',headers=headers)).json()['nickname']=='Михаил'


@pytest.mark.anyio
async def test_share_creation_reuse_guest_metadata_and_revoke(service):
    app, db=service
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app),base_url='http://test') as c:
        alice={'user':'alice','x-csrf-token':'valid'};bob={'user':'bob','x-csrf-token':'valid'}
        assert (await c.post('/api/shares',json={'kind':'likes'})).status_code==401
        assert (await c.post('/api/shares',headers=bob,json={'kind':'playlist','playlist_id':'p1'})).status_code==404
        result=await c.post('/api/shares',headers=alice,json={'kind':'playlist','playlist_id':'p1'})
        assert result.status_code==200
        token=result.json()['token'];assert len(token)==32
        assert (await c.post('/api/shares',headers=alice,json={'kind':'playlist','playlist_id':'p1'})).json()['token']==token
        public=(await c.get('/api/shares/'+token)).json()
        assert [t['id'] for t in public['tracks']]==['t1']
        assert 'file' not in public['tracks'][0] and 'rights' not in public['tracks'][0]
        assert (await c.delete('/api/shares/'+token,headers=bob)).status_code==404
        assert (await c.delete('/api/shares/'+token,headers=alice)).status_code==200
        assert (await c.get('/api/shares/'+token)).status_code==404
        new=(await c.post('/api/shares',headers=alice,json={'kind':'playlist','playlist_id':'p1'})).json()['token']
        assert new!=token
        with db() as database: database.execute("DELETE FROM playlists WHERE id='p1'")
        assert (await c.get('/api/shares/'+new)).status_code==404


def test_installer_preserves_existing_modules_and_rolls_back(tmp_path):
    app='''import server as core
def session(request,required=True): pass
def public(row): pass
def premium_csrf(request): pass
# Existing Audius and adaptive wave hooks must survive.
app = object()
'''
    (tmp_path/'app.py').write_text(app)
    (tmp_path/'web').mkdir();(tmp_path/'web/index.html').write_text('<body>Current restored UI</body>')
    (tmp_path/'audius_catalog.py').write_text('# installed')
    result=install_files(tmp_path)
    assert (tmp_path/'app.py').read_text().startswith(app.rstrip())
    assert (tmp_path/'audius_catalog.py').read_text()=='# installed'
    assert (tmp_path/'web/index.html').read_text().count('profile-workspace.js')==1
    assert not install_files(tmp_path)['changed']
    rollback(result['backup'])
    assert (tmp_path/'app.py').read_text()==app
    assert (tmp_path/'web/index.html').read_text()=='<body>Current restored UI</body>'


def test_installer_rejects_unrecognized_server(tmp_path):
    (tmp_path/'app.py').write_text('print("different app")')
    with pytest.raises(ValueError): install_files(tmp_path)
    assert (tmp_path/'app.py').read_text()=='print("different app")'
