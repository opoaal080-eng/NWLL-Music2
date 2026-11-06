import asyncio
from contextlib import contextmanager
import json
from pathlib import Path
import sqlite3
import tempfile
import time
import unittest

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
import legacy_preferences
from adaptive_wave import install


class ApiTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.db_path = self.root / 'music.db'
        self.prefs = self.root / 'preferences.sqlite3'
        outer = self
        class Core:
            @staticmethod
            @contextmanager
            def db():
                conn = sqlite3.connect(outer.db_path, timeout=10)
                conn.row_factory = sqlite3.Row
                try:
                    with conn:
                        yield conn
                finally:
                    conn.close()
        self.core = Core
        with Core.db() as conn:
            conn.executescript('''
              CREATE TABLE tracks(id TEXT PRIMARY KEY,title TEXT,artist TEXT,album TEXT,duration REAL,file TEXT,color TEXT,rights TEXT,cover TEXT);
              CREATE TABLE likes(user_id TEXT,track_id TEXT,PRIMARY KEY(user_id,track_id));
              CREATE TABLE playlists(id TEXT,user_id TEXT,name TEXT);
              CREATE TABLE playlist_tracks(playlist_id TEXT,track_id TEXT,position INTEGER);
              CREATE TABLE listening_sessions(user_id TEXT,session_id TEXT,track_id TEXT,listened REAL,skipped INTEGER,started REAL,updated REAL,PRIMARY KEY(user_id,session_id));
            ''')
            for letter in 'ABCD':
                for n in range(15):
                    tid = letter+str(n)
                    conn.execute('INSERT INTO tracks VALUES(?,?,?,?,?,?,?,?,?)', (tid,'Song '+tid,'Artist '+letter,'',200,'','',json.dumps({'status':'approved','language':'en'}),''))
            conn.executemany('INSERT INTO likes VALUES(?,?)', [('alice','A0'),('alice','A1'),('bob','B0'),('bob','B1')])
        self.app = FastAPI()
        @self.app.middleware('http')
        async def guard(request, call_next):
            if request.headers.get('origin') == 'https://evil.example':
                return JSONResponse({'error':'blocked'},403)
            return await call_next(request)
        @self.app.get('/api/wave')
        @self.app.get('/api/recommendations')
        @self.app.get('/api/wave-artists/mix')
        async def old():
            raise AssertionError('Old recommendation wrapper was called')
        @self.app.get('/ping')
        async def ping():
            return {'ok':True}
        @self.app.post('/api/listening')
        async def report(request: Request):
            data = await request.json()
            with Core.db() as conn:
                conn.execute('INSERT OR REPLACE INTO listening_sessions VALUES(?,?,?,?,?,?,?)', (request.cookies['account'],data['session_id'],data['track_id'],data['seconds'],int(data.get('skipped',False)),time.time()-data['seconds'],time.time()))
            return {'ok':True}
        def identity(request, required=True):
            return {'user_id':request.cookies['account']} if request.cookies.get('account') else None
        self.scheduled = []
        def public(row):
            return {key:row[key] for key in ['id','title','artist','duration']}
        install(self.app,Core,identity,public,
                scheduler=lambda account,seeds,excluded:self.scheduled.append((account['user_id'],seeds)),
                hidden_preferences=lambda uid:({'A2'} if uid=='alice' else set(),set()),
                artist_preferences_path=self.prefs, settings_module=legacy_preferences)
        self.client = httpx.AsyncClient(transport=httpx.ASGITransport(app=self.app),base_url='http://test',cookies={'account':'alice'})

    async def asyncTearDown(self):
        await self.client.aclose()
        self.temp.cleanup()

    async def test_all_clients_use_one_policy(self):
        for path in ['/api/wave','/api/recommendations','/api/wave-artists/mix']:
            response = await self.client.get(path,params={'mix':'same'})
            self.assertEqual(response.status_code,200)
            self.assertEqual(response.json()['recommendation_engine'],'adaptive-wave-3.0')
            self.assertNotIn('A2',[track['id'] for track in response.json()['tracks']])
        for path in ['/api/wave','/api/recommendations','/api/wave-artists/mix']:
            self.assertEqual(sum(route.path==path for route in self.app.routes),1)

    async def test_same_nonce_is_idempotent(self):
        first = await self.client.get('/api/wave',params={'mix':'nonce'})
        second = await self.client.get('/api/wave',params={'mix':'nonce'})
        self.assertEqual(first.json(),second.json())

    async def test_accounts_keep_separate_profiles(self):
        alice = (await self.client.get('/api/wave',params={'mix':'nonce'})).json()['tracks']
        bob = (await self.client.get('/api/wave',params={'mix':'nonce'},cookies={'account':'bob'})).json()['tracks']
        self.assertEqual(alice[0]['artist'],'Artist A')
        self.assertEqual(bob[0]['artist'],'Artist B')

    async def test_existing_csrf_origin_guard_is_preserved(self):
        response = await self.client.get('/api/wave',headers={'origin':'https://evil.example'})
        self.assertEqual(response.status_code,403)

    async def test_unauthenticated_requests_do_not_leak_taste(self):
        client = httpx.AsyncClient(transport=httpx.ASGITransport(app=self.app),base_url='http://test')
        async with client:
            self.assertEqual((await client.get('/api/wave')).json(),{'tracks':[],'personalized':False})
            self.assertEqual((await client.get('/api/recommendations/status')).status_code,401)
            self.assertEqual((await client.get('/api/wave-artists/mix')).status_code,401)

    async def test_new_mix_prefers_not_yet_offered_recordings(self):
        first = (await self.client.get('/api/wave',params={'mix':'one'})).json()['tracks']
        second = (await self.client.get('/api/wave',params={'mix':'two'})).json()['tracks']
        self.assertTrue({track['id'] for track in first}.isdisjoint(track['id'] for track in second))

    async def test_updated_feedback_invalidates_cached_response(self):
        original = (await self.client.get('/api/wave',params={'mix':'nonce'})).json()['tracks']
        bad = original[0]['id']
        await self.client.post('/api/listening',json={'session_id':'session-one','track_id':bad,'seconds':8,'skipped':True})
        changed = (await self.client.get('/api/wave',params={'mix':'nonce'})).json()['tracks']
        self.assertNotIn(bad,[track['id'] for track in changed])

    async def test_cached_tracks_are_rechecked_for_revocation(self):
        original = (await self.client.get('/api/wave',params={'mix':'nonce'})).json()['tracks']
        removed = original[0]['id']
        with self.core.db() as conn:
            conn.execute('UPDATE tracks SET rights=? WHERE id=?',(json.dumps({'status':'revoked'}),removed))
        changed = (await self.client.get('/api/wave',params={'mix':'nonce'})).json()['tracks']
        self.assertNotIn(removed,[track['id'] for track in changed])

    async def test_artist_selection_is_read_from_existing_storage(self):
        conn = sqlite3.connect(self.prefs)
        conn.execute('CREATE TABLE wave_favourite_artists(owner TEXT PRIMARY KEY,artists_json TEXT,updated REAL)')
        conn.execute('INSERT INTO wave_favourite_artists VALUES(?,?,?)',('alice',json.dumps(['Artist C']),time.time()))
        conn.commit();conn.close()
        result = (await self.client.get('/api/wave-artists/mix',params={'mix':'new'})).json()
        self.assertTrue(result['artist_preferences_applied'])
        self.assertEqual(result['tracks'][0]['artist'],'Artist C')

    async def test_invalid_settings_and_excessive_queue_are_rejected(self):
        self.assertEqual((await self.client.get('/api/wave',params={'mood':'bad'})).status_code,400)
        self.assertEqual((await self.client.get('/api/wave',params={'exclude':'x'*16001})).status_code,400)

    async def test_similar_listeners_add_a_nearby_discovery_signal(self):
        with self.core.db() as conn:
            conn.executemany('INSERT INTO likes VALUES(?,?)', [('bob','A0'),('bob','A1'),('bob','C5'),('bob','C6')])
        result = (await self.client.get('/api/wave',params={'mix':'neighbour'})).json()['tracks']
        self.assertTrue({'C5','C6'} & {track['id'] for track in result[:6]})
        self.assertFalse(any('user_id' in track for track in result))

    async def test_concurrent_batches_keep_unoffered_tracks_separate(self):
        first, second = await asyncio.gather(self.client.get('/api/wave',params={'mix':'one'}),self.client.get('/api/wave',params={'mix':'two'}))
        self.assertTrue({track['id'] for track in first.json()['tracks']}.isdisjoint(track['id'] for track in second.json()['tracks']))

    async def test_worker_does_not_block_fastapi_event_loop(self):
        engine = self.app.state.nw_adaptive_wave_engine
        original = engine.choose
        def slow(*args):
            time.sleep(.4)
            return original(*args)
        engine.choose = slow
        wave = asyncio.create_task(self.client.get('/api/wave'))
        await asyncio.sleep(.03)
        started = time.monotonic()
        self.assertEqual((await self.client.get('/ping')).status_code,200)
        self.assertLess(time.monotonic()-started,.20)
        await wave


if __name__ == '__main__':
    unittest.main()
