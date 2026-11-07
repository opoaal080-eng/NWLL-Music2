"""FastAPI integration for one ranking policy on all Nightwell wave routes.

Uses the existing authentication, catalog rights, preferences and listening API.
Selection and SQLite work run in a worker thread. Discovery remains asynchronous.
No models, audio files, new external services or client changes are required.
"""
import asyncio
from collections import Counter, OrderedDict
from contextlib import contextmanager
import hashlib
import json
from pathlib import Path
import sqlite3
import threading
import time

from fastapi import HTTPException, Request
from fastapi.routing import APIRoute
from wave_ranker import artists, build_profile, key, number, rank, track_info

VERSION = 'adaptive-wave-3.0'
PATHS = {'/api/wave', '/api/recommendations', '/api/wave-artists/mix'}
MAX_CATALOG = 25000


class WaveEngine:
    def __init__(self, core, public, artist_preferences_path, hidden_preferences=None, settings_module=None):
        self.core, self.public = core, public
        self.artist_preferences_path = Path(artist_preferences_path).resolve()
        self.hidden_preferences = hidden_preferences
        if settings_module is None:
            import wave_preferences as settings_module
        self.settings = settings_module
        self._schema_ready = False
        self._guard = threading.Lock()
        self._locks = OrderedDict()
        self._cache = OrderedDict()

    @contextmanager
    def user_lock(self, owner):
        with self._guard:
            # Locks with active/waiting users are retained; inactive entries can expire.
            entry = self._locks.get(owner)
            if entry is None:
                entry = [threading.Lock(), 0]
                self._locks[owner] = entry
            entry[1] += 1
            self._locks.move_to_end(owner)
        try:
            with entry[0]:
                yield
        finally:
            with self._guard:
                entry[1] -= 1
                while len(self._locks) > 256:
                    removable = next((uid for uid, (_, active) in self._locks.items() if active == 0), None)
                    if removable is None:
                        break
                    del self._locks[removable]

    def schema(self):
        with self._guard:
            if self._schema_ready:
                return
            with self.core.db() as conn:
                conn.execute('''CREATE TABLE IF NOT EXISTS nw_wave_deliveries (
                    owner TEXT NOT NULL, recording TEXT NOT NULL, issued REAL NOT NULL,
                    PRIMARY KEY(owner, recording))''')
                conn.execute('CREATE INDEX IF NOT EXISTS nw_wave_delivery_age ON nw_wave_deliveries(issued)')
            self._schema_ready = True

    def selected_artists(self, owner):
        path = self.artist_preferences_path
        if not path.is_file():
            return []
        # Read-only: do not create or modify the preferences database.
        conn = sqlite3.connect(path.as_uri() + '?mode=ro', uri=True, timeout=3)
        try:
            names = conn.execute('SELECT artists_json FROM wave_favourite_artists WHERE owner=?', (owner,)).fetchone()
            value = json.loads(names[0]) if names else []
            return [v for v in value[:20] if isinstance(v, str)] if isinstance(value, list) else []
        except (sqlite3.OperationalError, ValueError, TypeError):
            return []
        finally:
            conn.close()

    def snapshot(self, owner):
        self.schema()
        with self.core.db() as conn:
            rows = [dict(row) for row in conn.execute('SELECT * FROM tracks ORDER BY rowid DESC LIMIT ?', (MAX_CATALOG,))]
            likes = {row[0] for row in conn.execute('SELECT track_id FROM likes WHERE user_id=?', (owner,))}
            saved = {row[0] for row in conn.execute('''SELECT DISTINCT pt.track_id FROM playlist_tracks pt
                JOIN playlists p ON p.id=pt.playlist_id WHERE p.user_id=?''', (owner,))}
            events = [dict(row) for row in conn.execute('SELECT * FROM listening_sessions WHERE user_id=? ORDER BY updated DESC LIMIT 3000', (owner,))]
            missing = list((likes | saved | {event['track_id'] for event in events}) - {row['id'] for row in rows})
            for start in range(0, len(missing), 400):
                chunk = missing[start:start+400]
                rows.extend(dict(row) for row in conn.execute('SELECT * FROM tracks WHERE id IN (' + ','.join('?' for _ in chunk) + ')', chunk))
            exposure = dict(conn.execute('SELECT recording,issued FROM nw_wave_deliveries WHERE owner=? AND issued>?', (owner, time.time()-3600)))
            peer = Counter()
            # Aggregate neighbours from overlap in likes; identities never leave the server.
            neighbours = list(conn.execute('''SELECT other.user_id,COUNT(*) AS common FROM likes own
                JOIN likes other ON other.track_id=own.track_id
                WHERE own.user_id=? AND other.user_id<>? GROUP BY other.user_id
                HAVING COUNT(*)>=2 ORDER BY common DESC LIMIT 24''', (owner, owner)))
            for other, common in neighbours:
                other_tracks = list(conn.execute('SELECT track_id FROM likes WHERE user_id=? LIMIT 1000', (other,)))
                similarity = min(1.0, common / max(1, len(likes) * max(1, len(other_tracks))) ** .5)
                for row in other_tracks:
                    if row[0] not in likes:
                        peer[row[0]] += similarity
        preferred = self.selected_artists(owner)
        hidden_ids, hidden_artists = self.hidden_preferences(owner) if self.hidden_preferences else (set(), set())
        items = [track_info(row) for row in rows]
        return items, likes, saved, events, preferred, set(hidden_ids), set(hidden_artists), exposure, peer

    def choose(self, owner, params, limit):
        with self.user_lock(owner):
            now = time.time()
            settings = self.settings.preferences(params)
            items, likes, saved, events, preferred, hidden_ids, hidden_artists, exposure, peer = self.snapshot(owner)
            excluded = {value for value in params.get('exclude', '').split(',') if value}
            nonce = params.get('mix', '') or str(int(now // 10))
            profile = build_profile(items, likes, saved, events, preferred, now)
            feedback = hashlib.sha256(json.dumps([
                sorted(likes), sorted(saved), sorted(hidden_ids), sorted(hidden_artists), preferred,
                [(e['session_id'], e['updated'], e['listened'], e['skipped']) for e in events[:50]],
            ], ensure_ascii=False, sort_keys=True).encode()).hexdigest()
            cache_key = (owner, nonce, tuple(sorted(settings.items())), params.get('exclude', ''), feedback, limit)
            with self._guard:
                cached = self._cache.get(cache_key)
            if params.get('mix') and cached and cached[0] > now:
                with self.core.db() as conn:
                    approved = {row['id'] for row in conn.execute('SELECT * FROM tracks WHERE id IN (' + ','.join('?' for _ in cached[1]) + ')', [item['id'] for item in cached[1]]) if track_info(row).rights.get('status') == 'approved'} if cached[1] else set()
                result = [item for item in cached[1] if item['id'] in approved]
            else:
                chosen = rank(items, profile, likes, saved, excluded, hidden_ids, hidden_artists, exposure,
                              settings, self.settings.eligible, self.settings.boost, peer,
                              nonce, owner, now, limit)
                # Recheck current publication rights, including rows from a long snapshot.
                chosen_ids = [item.id for item in chosen]
                with self.core.db() as conn:
                    fresh = {row['id']: row for row in conn.execute('SELECT * FROM tracks WHERE id IN (' + ','.join('?' for _ in chosen_ids) + ')', chosen_ids)} if chosen_ids else {}
                    result = []
                    for item in chosen:
                        row = fresh.get(item.id)
                        if row is None or track_info(row).rights.get('status') != 'approved':
                            continue
                        result.append(self.public(row))
                        conn.execute('INSERT INTO nw_wave_deliveries(owner,recording,issued) VALUES(?,?,?) ON CONFLICT(owner,recording) DO UPDATE SET issued=excluded.issued', (owner, item.recording, now))
                    conn.execute('DELETE FROM nw_wave_deliveries WHERE issued<?', (now-2*86400,))
                if params.get('mix'):
                    with self._guard:
                        self._cache[cache_key] = (now+15, result)
                        self._cache.move_to_end(cache_key)
                        while len(self._cache) > 128:
                            self._cache.popitem(last=False)
            display = {key(name): name for name in preferred}
            for item in items:
                for name in str(item.row.get('artist') or '').split(','):
                    display.setdefault(key(name), name.strip())
            seed_names = [display.get(name, name) for name, value in profile.artist.most_common(8) if value > 0][:3]
            seed_names = self.settings.seeds(seed_names or preferred[:3] or ['русская музыка', 'pop'], settings)
            return {
                'tracks': result, 'personalized': profile.positive,
                'wave_preferences': settings, 'artist_preferences_applied': bool(preferred),
                'recommendation_engine': VERSION, 'retry_after': 5 if not result else 30,
                'message': '' if result else 'Сейчас нет новых подходящих треков. Подбираем следующую порцию.',
            }, seed_names, excluded


def install(app, core, session, public, scheduler=None, hidden_preferences=None,
            artist_preferences_path=None, settings_module=None):
    if getattr(app.state, 'nw_adaptive_wave_installed', False):
        return
    engine = WaveEngine(core, public,
                        artist_preferences_path or Path(__file__).with_name('nightwell_artist_preferences.sqlite3'),
                        hidden_preferences, settings_module)
    # Replace complete routes so FastAPI rebuilds dependency/parameter handling.
    app.router.routes[:] = [route for route in app.router.routes
                           if not (isinstance(route, APIRoute) and route.path in PATHS and 'GET' in route.methods)]

    @app.get('/api/wave')
    @app.get('/api/recommendations')
    @app.get('/api/wave-artists/mix')
    async def wave(request: Request, exclude: str = '', mix: str = '',
                   character: str = 'balanced', mood: str = 'any', language: str = 'any'):
        account = await asyncio.to_thread(session, request, False)
        if not account:
            if request.url.path == '/api/wave-artists/mix':
                raise HTTPException(401, 'Войди в Nightwell Music')
            return {'tracks': [], 'personalized': False}
        if len(exclude) > 16000 or len(mix) > 160:
            raise HTTPException(400, 'Слишком длинная очередь или код подборки')
        owner = str(account['user_id'])
        params = {'exclude': exclude, 'mix': mix[:80], 'character': character, 'mood': mood, 'language': language}
        try:
            limit = 60 if request.url.path == '/api/recommendations' else 20
            payload, seeds, excluded_ids = await asyncio.to_thread(engine.choose, owner, params, limit)
        except ValueError as error:
            raise HTTPException(400, str(error))
        # Existing discovery is scheduled, never awaited on the first track.
        if scheduler and character != 'favorites' and seeds:
            try:
                scheduler(account, seeds, excluded_ids)
            except Exception:
                import logging
                logging.getLogger(__name__).warning('Wave discovery could not be scheduled', exc_info=True)
        # Optional sources share the same catalogue and ranking policy. Never
        # append unranked provider results or block playback on discovery.
        extra = getattr(app.state, 'nw_audius_service', None)
        if extra and character != 'favorites' and seeds:
            extra.schedule(account, seeds, excluded_ids)
        return payload

    @app.get('/api/recommendations/status')
    async def status(request: Request):
        account = await asyncio.to_thread(session, request, False)
        if not account:
            raise HTTPException(401, 'Войди в Nightwell Music')
        return {'version': VERSION, 'routes': sorted(PATHS),
                'signals': ['likes', 'saved_tracks', 'listening', 'skips', 'selected_artists'],
                'shared_policy': True}

    app.state.nw_adaptive_wave_installed = True
    app.state.nw_adaptive_wave_engine = engine
