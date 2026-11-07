import asyncio
from contextlib import contextmanager
import json
from pathlib import Path
import sqlite3
import time
from types import SimpleNamespace

import httpx
import pytest
import pytest_asyncio
from fastapi import FastAPI, HTTPException, Request

from audius_catalog import install, relevance
from audius_provider import AudiusError, normalize
from test_provider import raw_track


class AudioBytes(httpx.AsyncByteStream):
    async def __aiter__(self):
        yield b'1234'


def test_exact_cross_source_match_is_not_buried_beyond_import_limit():
    loose=[{'id':str(i),'title':'Song remix '+str(i),'artist':'Other'} for i in range(250)]
    exact={'id':'audius_abc12','title':'Song','artist':'Artist'}
    ranked=sorted(loose+[exact], key=lambda item:relevance('Artist Song',item))
    assert ranked[0]==exact


class Provider:
    def __init__(self):
        self.calls = []
        self.slow = 0
        self.broken = False
        self.gated = False
        self.items = [normalize(raw_track())]
        self.ranges = []
        self.responses = []
    async def search(self, query, offset=0):
        self.calls.append((query, offset))
        if self.slow:
            await asyncio.sleep(self.slow)
        if self.broken:
            raise AudiusError()
        return self.items
    async def track(self, tid):
        if self.gated:
            raise AudiusError('not available', 404)
        return next(item for item in self.items if item['rights']['audius_id'] == tid)
    async def audio(self, tid, range_header=None):
        self.ranges.append(range_header)
        transport = httpx.MockTransport(lambda r: httpx.Response(
            206 if range_header else 200, stream=AudioBytes(),
            headers={'Content-Type':'audio/mpeg', 'Content-Length':'4', 'Content-Range':'bytes 0-3/4', 'Accept-Ranges':'bytes'}))
        client = httpx.AsyncClient(transport=transport)
        response = await client.send(client.build_request('GET','https://cdn.audius.co/x'),stream=True)
        self.responses.append((response, client))
        return response, client
    async def cover(self, url):
        return b'\xff\xd8\xfftest', 'image/jpeg'


@pytest_asyncio.fixture
async def env(tmp_path):
    @contextmanager
    def db():
        conn = sqlite3.connect(tmp_path/'music.db', timeout=10)
        conn.row_factory = sqlite3.Row
        try:
            with conn:
                yield conn
        finally:
            conn.close()
    core = SimpleNamespace(db=db)
    with db() as conn:
        conn.executescript('''
            CREATE TABLE tracks(id TEXT PRIMARY KEY,title TEXT,artist TEXT,album TEXT,duration REAL,file TEXT,color TEXT,rights TEXT,cover TEXT);
            CREATE TABLE likes(user_id TEXT,track_id TEXT,PRIMARY KEY(user_id,track_id));
            CREATE TABLE playlists(id TEXT PRIMARY KEY,user_id TEXT,name TEXT);
            CREATE TABLE playlist_tracks(playlist_id TEXT,track_id TEXT,position INTEGER,PRIMARY KEY(playlist_id,track_id));
            CREATE TABLE listening_sessions(user_id TEXT,session_id TEXT,track_id TEXT,listened REAL,skipped INTEGER,started REAL,updated REAL,PRIMARY KEY(user_id,session_id));
        ''')
        conn.execute('INSERT INTO tracks VALUES(?,?,?,?,?,?,?,?,?)', ('local','Existing','Other','',180,'a.mp3','#777',json.dumps({'status':'approved'}),''))
    app = FastAPI()
    def session(request, required=True):
        if request.cookies.get('account'):
            return {'user_id': request.cookies['account']}
        if required:
            raise HTTPException(401)
        return None
    def track(conn, tid, request):
        row = conn.execute('SELECT * FROM tracks WHERE id=?',(tid,)).fetchone()
        if not row or not session(request,False) or json.loads(row['rights']).get('status') != 'approved':
            raise HTTPException(404)
        return row
    def public(row):
        return {k:row[k] for k in ('id','title','artist','duration')}
    ns = {'app':app,'core':core,'session':session,'public':public,'track':track}
    @app.get('/api/tracks')
    async def tracks(request: Request, q: str = ''):
        if not session(request,False):
            return {'tracks':[]}
        with db() as conn:
            return {'tracks':[ns['public'](r) for r in conn.execute('SELECT * FROM tracks')
                              if json.loads(r['rights']).get('status')=='approved' and (not q or q=='Existing')]}
    @app.api_route('/api/stream/{tid}', methods=['GET','HEAD'])
    async def stream(tid: str, request: Request):
        session(request)
        return {'old_stream':tid}
    @app.get('/api/covers/{tid}')
    async def cover(tid: str, request: Request):
        return {'old_cover':tid}
    @app.get('/api/offline-export/{tid}')
    def offline(tid: str, request: Request):
        return {'status':'ready'}
    @app.post('/api/playlists')
    async def playlist(request: Request):
        owner=session(request)['user_id']; body=await request.json()
        with db() as conn:
            conn.execute('INSERT INTO playlists VALUES(?,?,?)',('imported',owner,body['name']))
        return {'id':'imported'}
    @app.post('/api/playlists/{pid}/tracks/{tid}')
    async def playlist_track(pid: str, tid: str, request: Request):
        owner=session(request)['user_id']
        with db() as conn:
            track(conn,tid,request)
            if not conn.execute('SELECT 1 FROM playlists WHERE id=? AND user_id=?',(pid,owner)).fetchone():
                raise HTTPException(404)
            conn.execute('INSERT OR IGNORE INTO playlist_tracks VALUES(?,?,?)',(pid,tid,1))
        return {'ok':True}
    provider=Provider()
    service=install(ns,provider)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app),base_url='http://test',cookies={'account':'alice'}) as client:
        yield SimpleNamespace(app=app, ns=ns, core=core, provider=provider, service=service, client=client, root=tmp_path)
    await service.close()


@pytest.mark.asyncio
async def test_search_saves_stable_ids_and_public_cover(env):
    first=(await env.client.get('/api/tracks',params={'q':'Artist Song'})).json()
    second=(await env.client.get('/api/tracks',params={'q':'Artist Song'})).json()
    assert first==second
    assert first['tracks'][0]['id']=='audius_abc12'
    assert first['tracks'][0]['cover_url']=='/api/covers/audius_abc12'
    assert len(env.provider.calls)==1
    env.service.publish(env.provider.items)
    with env.core.db() as conn:
        assert conn.execute("SELECT COUNT(*) FROM tracks WHERE id='audius_abc12'").fetchone()[0]==1


@pytest.mark.asyncio
async def test_slow_search_stays_pending_and_reuses_inflight(env):
    env.provider.slow=.08
    a,b=await asyncio.gather(env.service.search('slow',budget=.001),env.service.search('slow',budget=.001))
    assert a[1] and b[1]
    assert len(env.provider.calls)==1
    await asyncio.gather(*env.service.pending.values())
    rows,pending,error=await env.service.search('slow')
    assert rows and not pending and not error
    assert len(env.provider.calls)==1


@pytest.mark.asyncio
async def test_provider_failure_keeps_other_source_and_anonymous_no_requests(env):
    env.provider.broken=True
    response=await env.client.get('/api/tracks',params={'q':'Existing'})
    assert response.status_code==200
    assert response.json()['tracks'][0]['id']=='local'
    assert response.json()['audius_message']
    env.client.cookies.clear()
    await env.client.get('/api/tracks',params={'q':'Other'})
    assert len(env.provider.calls)==1
    assert (await env.client.get('/api/audius/status')).status_code==401


@pytest.mark.asyncio
async def test_playback_range_head_cover_and_legacy_routes(env):
    env.service.publish(env.provider.items)
    r=await env.client.get('/api/stream/audius_abc12',headers={'range':'bytes=0-3'})
    assert r.status_code==206 and r.content==b'1234'
    assert r.headers['content-range']=='bytes 0-3/4'
    assert env.provider.ranges==['bytes=0-3']
    r=await env.client.head('/api/stream/audius_abc12')
    assert r.content==b'' and r.headers['content-length']=='4'
    assert all(r.is_closed and c.is_closed for r,c in env.provider.responses)
    assert (await env.client.get('/api/covers/audius_abc12')).headers['content-type']=='image/jpeg'
    assert (await env.client.get('/api/stream/local')).json()=={'old_stream':'local'}
    env.client.cookies.clear()
    assert (await env.client.get('/api/stream/audius_abc12')).status_code==401


@pytest.mark.asyncio
async def test_revocation_and_download_gating(env):
    env.service.publish(env.provider.items)
    env.provider.items[0]['rights']['downloadable']=False
    assert (await env.client.get('/api/offline-export/audius_abc12')).status_code==403
    env.provider.gated=True
    assert (await env.client.get('/api/stream/audius_abc12')).status_code==404
    with env.core.db() as conn:
        assert json.loads(conn.execute("SELECT rights FROM tracks WHERE id='audius_abc12'").fetchone()[0])['status']=='unavailable'
    env.service.publish(env.provider.items)
    assert env.service.rows(['audius_abc12'])==[]


@pytest.mark.asyncio
async def test_real_import_module_finds_and_saves_audius(env):
    from music_import import install as install_import
    jobs=install_import(env.app,lambda r: env.ns['session'](r)['user_id'],
                        lambda r:r.headers.get('x-csrf-token')=='test',env.root/'imports.db')
    r=await env.client.post('/api/imports',json={'provider':'yandex','text':'Artist - Song'},headers={'x-csrf-token':'test'})
    key=r.json()['id']
    await asyncio.gather(*jobs.tasks)
    job=(await env.client.get('/api/imports/'+key)).json()
    assert job['state']=='ready' and job['matched']==1
    assert job['items'][0]['track_id']=='audius_abc12'
    await env.client.post('/api/imports/'+key+'/commit',headers={'x-csrf-token':'test'})
    await asyncio.gather(*jobs.tasks)
    assert (await env.client.get('/api/imports/'+key)).json()['state']=='done'
    with env.core.db() as conn:
        assert conn.execute('SELECT track_id FROM playlist_tracks').fetchone()[0]=='audius_abc12'


@pytest.mark.asyncio
async def test_wave_discovers_audius_but_ranks_hides_and_deduplicates(env):
    from adaptive_wave import install as install_wave
    # Use shipped preference code rather than a permissive test stub.
    import importlib.util
    source=Path(__file__).resolve().parents[4]/'server-reference'/'wave_preferences.py'
    # CI uses the legacy preference fixture from adaptive-wave's tests.
    if not source.is_file():
        source=Path(__file__).resolve().parents[2]/'adaptive-wave'/'tests'/'legacy_preferences.py'
    spec=importlib.util.spec_from_file_location('test_wave_preferences',source)
    settings=importlib.util.module_from_spec(spec);spec.loader.exec_module(settings)
    env.provider.items=[normalize(raw_track(id=str(i),title='Track '+str(i))) for i in range(10)]
    env.service.publish([env.provider.items[0]])
    with env.core.db() as conn:
        conn.execute('INSERT INTO likes VALUES(?,?)',('alice','audius_0'))
        for i in range(2):
            conn.execute('INSERT INTO listening_sessions VALUES(?,?,?,?,?,?,?)',
                         ('alice',str(i),'audius_2',8,1,time.time()-60,time.time()-30))
    install_wave(env.app,env.core,env.ns['session'],env.ns['public'],
                 hidden_preferences=lambda uid:({'audius_1'},set()),settings_module=settings,
                 artist_preferences_path=env.root/'prefs.db')
    first=await env.client.get('/api/wave',params={'mix':'first'})
    assert first.status_code==200
    await asyncio.gather(*env.service.discovery_jobs.values())
    assert env.provider.calls and env.provider.calls[0][0]=='Artist'
    with env.core.db() as conn:
        conn.execute('INSERT INTO tracks VALUES(?,?,?,?,?,?,?,?,?)',
                     ('sc_duplicate','Track 4','Artist','',180,'','#777',json.dumps({'status':'approved','source':'soundcloud'}),''))
    second=(await env.client.get('/api/wave',params={'mix':'second','exclude':'audius_3'})).json()
    ids={t['id'] for t in second['tracks']}
    assert ids & {'audius_'+str(i) for i in range(4,10)}
    assert not ids & {'audius_1','audius_2','audius_3'}
    assert len(ids & {'audius_4','sc_duplicate'})<=1
    assert all(t.get('source')=='audius' for t in second['tracks'] if t['id'].startswith('audius_'))
    before=len(env.provider.calls)
    await env.client.get('/api/wave',params={'mix':'favorites','character':'favorites'})
    assert len(env.provider.calls)==before
