"""Actual adaptive engine regressions, isolated from FastAPI and providers."""
import ast
import asyncio
from contextlib import contextmanager
import json
from pathlib import Path
import sqlite3
import tempfile
from types import SimpleNamespace
import unittest

from wave_ranker import build_profile, rank, track_info


ROOT = Path(__file__).parent


class FakeRoute:
    def __init__(self, path, endpoint):
        self.path, self.endpoint, self.methods = path, endpoint, {'GET'}


class FakeApp:
    def __init__(self):
        self.state = SimpleNamespace()
        self.router = SimpleNamespace(routes=[])

    def get(self, path):
        def register(endpoint):
            self.router.routes.append(FakeRoute(path, endpoint))
            return endpoint
        return register


def load_adapter():
    tree = ast.parse((ROOT / 'adaptive_wave.py').read_text())
    tree.body = [node for node in tree.body
                 if not isinstance(node, ast.ImportFrom) or not node.module.startswith('fastapi')]
    namespace = {'Request': object, 'HTTPException': ValueError, 'APIRoute': FakeRoute,
                 '__file__': str(ROOT / 'adaptive_wave.py')}
    exec(compile(tree, '<adaptive adapter>', 'exec'), namespace)
    # Provider fakes and SQLite calls need no executor; run actual async routes
    # without starting a default threadpool in the managed test sandbox.
    async def direct(function, *args):
        return function(*args)
    namespace['asyncio'] = SimpleNamespace(to_thread=direct, create_task=asyncio.create_task,
                                         wait_for=asyncio.wait_for, shield=asyncio.shield,
                                         CancelledError=asyncio.CancelledError)
    return namespace


def row(ident, source, artist='Performer', title=None, approved=True):
    return dict(id=ident, title=title or ('Song ' + ident), artist=artist,
                album='', duration=180, rights=json.dumps(
                    dict(status='approved' if approved else 'draft', source=source)))


class Store:
    def __init__(self, rows):
        self.folder = tempfile.TemporaryDirectory()
        self.path = Path(self.folder.name) / 'catalog.sqlite'
        with self.db() as connection:
            connection.executescript('''
                CREATE TABLE tracks(id TEXT PRIMARY KEY,title TEXT,artist TEXT,album TEXT,duration REAL,rights TEXT);
                CREATE TABLE likes(user_id TEXT,track_id TEXT);
                CREATE TABLE playlists(id TEXT,user_id TEXT);
                CREATE TABLE playlist_tracks(playlist_id TEXT,track_id TEXT);
                CREATE TABLE listening_sessions(session_id TEXT,track_id TEXT,user_id TEXT,updated REAL,listened REAL,skipped INTEGER);
            ''')
        self.add(rows)

    @contextmanager
    def db(self):
        connection = sqlite3.connect(self.path)
        connection.row_factory = sqlite3.Row
        try:
            with connection:
                yield connection
        finally:
            connection.close()

    def add(self, rows):
        with self.db() as connection:
            connection.executemany('INSERT OR REPLACE INTO tracks VALUES(?,?,?,?,?,?)',
                                   [tuple(item[field] for field in ('id','title','artist','album','duration','rights'))
                                    for item in rows])

    def close(self):
        self.folder.cleanup()


def settings():
    return SimpleNamespace(
        preferences=lambda params: {key: params.get(key, default) for key, default in
                                    [('character','balanced'),('mood','any'),('language','any')]},
        eligible=lambda item, preferences, likes, heard: item.get('album') != 'ineligible',
        boost=lambda *_: 0,
        seeds=lambda seeds, _: seeds)


PARAMS = dict(character='balanced', mood='any', language='any', mix='test-mix', exclude='')


class AdaptivePrimaryTests(unittest.TestCase):
    def engine(self, rows, hidden=None):
        store = Store(rows)
        self.addCleanup(store.close)
        module = load_adapter()
        engine = module['WaveEngine'](
            store, lambda item: dict(id=item['id'],source=json.loads(item['rights'])['source']),
            Path(store.folder.name) / 'absent-preferences.sqlite', hidden, settings())
        return engine, store

    def test_primary_beats_artist_diversity_exploration_and_audius_affinity(self):
        rows = [row('sc'+str(n), 'soundcloud', artist='Same artist') for n in range(20)]
        rows += [row('aud'+str(n), 'audius', artist='Other '+str(n)) for n in range(20)]
        engine, store = self.engine(rows)
        with store.db() as connection:
            connection.executemany('INSERT INTO likes VALUES(?,?)', [('owner','aud'+str(n)) for n in range(20)])
        payload, _, _ = engine.choose('owner', PARAMS, 20)
        self.assertEqual(len(payload['tracks']), 20)
        self.assertTrue(all(item['source'] == 'soundcloud' for item in payload['tracks']))
        self.assertFalse(engine.primary_shortage('owner', PARAMS, 20))

    def test_shortage_and_daily_limit_fill_only_after_all_primary(self):
        rows = [row('sc'+str(n), 'soundcloud') for n in range(20)]
        rows += [row('aud'+str(n), 'audius') for n in range(45)]
        engine, _ = self.engine(rows)
        payload, _, _ = engine.choose('owner', PARAMS, 60)
        self.assertEqual([item['source'] for item in payload['tracks']], ['soundcloud']*20 + ['audius']*40)
        self.assertTrue(engine.primary_shortage('owner', PARAMS, 60))

    def test_hidden_excluded_blocked_and_ineligible_primary_leave_fallback(self):
        import time
        rows = [row('hidden','soundcloud'), row('excluded','soundcloud'),
                row('blocked','soundcloud'), row('mood','soundcloud'), row('draft','soundcloud',approved=False),
                row('fallback','audius')]
        rows[3]['album'] = 'ineligible'
        engine, store = self.engine(rows, hidden=lambda _: ({'hidden'},set()))
        with store.db() as connection:
            connection.execute('INSERT INTO listening_sessions VALUES(?,?,?,?,?,?)',
                               ('skip','blocked','owner',time.time(),5,1))
        params = dict(PARAMS,exclude='excluded')
        payload, _, _ = engine.choose('owner', params, 20)
        self.assertEqual(payload['tracks'], [dict(id='fallback',source='audius')])

    def test_cross_source_recording_dedup_prefers_primary(self):
        engine, _ = self.engine([row('sc','soundcloud',title='One recording'),
                                 row('aud','audius',title='One recording')])
        payload, _, _ = engine.choose('owner', PARAMS, 20)
        self.assertEqual(payload['tracks'], [dict(id='sc',source='soundcloud')])

    def test_completed_discovery_invalidates_audius_mix_cache(self):
        engine, store = self.engine([row('aud'+str(n),'audius') for n in range(20)])
        first, _, _ = engine.choose('owner', PARAMS, 20)
        self.assertTrue(all(item['source']=='audius' for item in first['tracks']))
        store.add([row('sc'+str(n),'soundcloud') for n in range(20)])
        second, _, _ = engine.choose('owner', PARAMS, 20)
        self.assertTrue(all(item['source']=='soundcloud' for item in second['tracks']))


class AdapterSchedulingTests(unittest.IsolatedAsyncioTestCase):
    async def route(self, primary_count, *, delayed=False, enough_after=False, character='balanced'):
        module = load_adapter()
        app = FakeApp()
        calls = []
        completed = asyncio.Event()

        async def discover():
            if delayed:
                await completed.wait()
            calls.append('primary-complete')

        def schedule(*_):
            calls.append('primary-start')
            return asyncio.create_task(discover())

        app.state.nw_audius_service = SimpleNamespace(schedule=lambda *_: calls.append('audius'))
        module['install'](app, SimpleNamespace(), lambda *_: {'user_id':'owner'}, dict,
                          scheduler=schedule, settings_module=settings())
        engine = app.state.nw_adaptive_wave_engine
        payload = {'tracks':[dict(id='sc'+str(n),source='soundcloud') for n in range(primary_count)]}
        engine.choose = lambda *_: (payload,['Performer'],set())
        engine.primary_shortage = lambda *_: not enough_after
        route = next(route.endpoint for route in app.router.routes if route.path=='/api/wave')
        result = await route(SimpleNamespace(url=SimpleNamespace(path='/api/wave')), character=character)
        return app, calls, completed, result

    async def test_enough_primary_never_schedules_audius(self):
        app, calls, _, _ = await self.route(20)
        await asyncio.sleep(0)
        self.assertEqual(calls,['primary-start','primary-complete'])
        self.assertEqual(app.state.nw_adaptive_wave_fallback_jobs,{})

    async def test_fallback_waits_for_primary_then_rechecks_shortage(self):
        app, calls, completed, _ = await self.route(0,delayed=True)
        await asyncio.sleep(0)
        self.assertEqual(calls,['primary-start'])
        completed.set()
        await asyncio.gather(*list(app.state.nw_adaptive_wave_fallback_jobs.values()))
        await asyncio.sleep(0)
        self.assertEqual(calls,['primary-start','primary-complete','audius'])
        self.assertEqual(app.state.nw_adaptive_wave_fallback_jobs,{})

    async def test_primary_completion_can_remove_shortage(self):
        app, calls, completed, _ = await self.route(0,delayed=True,enough_after=True)
        completed.set()
        await asyncio.gather(*list(app.state.nw_adaptive_wave_fallback_jobs.values()))
        await asyncio.sleep(0)
        self.assertEqual(calls,['primary-start','primary-complete'])

    async def test_favorites_never_discovers_either_source(self):
        app, calls, _, _ = await self.route(0,character='favorites')
        self.assertEqual(calls,[])
        self.assertEqual(app.state.nw_adaptive_wave_fallback_jobs,{})


if __name__ == '__main__':
    unittest.main()
