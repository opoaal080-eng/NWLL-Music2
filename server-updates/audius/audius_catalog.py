"""Add Audius to Nightwell search/import, playback and Adaptive Wave v3.

Additive installation: no account changes, no client rebuild, no full server
replacement. Original handlers continue to serve all other sources.
"""
import asyncio
from collections import Counter, OrderedDict
from contextlib import asynccontextmanager
import inspect
import json
import logging
import re
import time
import unicodedata

from fastapi import HTTPException, Request
from fastapi.routing import APIRoute
from starlette.background import BackgroundTask
from starlette.responses import Response, StreamingResponse

from audius_provider import AudiusClient, AudiusError

LOG = logging.getLogger(__name__)
VERSION = 'audius-1.1-sc-backup'


def relevance(query, item):
    def words(value):
        return ' '.join(re.findall(r'[^\W_]+', unicodedata.normalize('NFKC', str(value)).casefold().replace('ё', 'е')))
    needle = words(query)
    title, artist = words(item.get('title', '')), words(item.get('artist', ''))
    exact = needle in (title, artist + ' ' + title, title + ' ' + artist)
    tokens = set(needle.split())
    overlap = len(tokens & set((title + ' ' + artist).split()))
    return (not exact, -overlap, needle not in title, needle not in artist)


async def call(function, *args, **kwargs):
    if inspect.iscoroutinefunction(function):
        return await function(*args, **kwargs)
    return await asyncio.to_thread(function, *args, **kwargs)


class AudiusCatalog:
    def __init__(self, ns, provider=None):
        self.ns, self.core = ns, ns['core']
        self.provider = provider or AudiusClient()
        self.cached = OrderedDict()
        self.pending = {}
        self.discovery_jobs = {}
        self.discovery_state = OrderedDict()
        self.covers = OrderedDict()
        self.enabled = True

    def publish(self, items):
        """Stable namespaced keys; repeat discovery never resets likes or paths."""
        with self.core.db() as conn:
            for item in items:
                current = conn.execute('SELECT rights FROM tracks WHERE id=?', (item['id'],)).fetchone()
                if current:
                    old = json.loads(current['rights'])
                    # Do not undo a manual moderation decision or change another source.
                    if old.get('source') != 'audius' or old.get('status') != 'approved':
                        continue
                conn.execute('''INSERT INTO tracks(id,title,artist,album,duration,file,color,rights,cover)
                    VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
                    title=excluded.title,artist=excluded.artist,duration=excluded.duration,rights=excluded.rights''',
                    (item['id'], item['title'], item['artist'], item['album'], item['duration'], '',
                     item['color'], json.dumps(item['rights'], ensure_ascii=False), ''))

    def rows(self, ids):
        if not ids:
            return []
        with self.core.db() as conn:
            result = {row['id']: self.ns['public'](row) for row in conn.execute(
                'SELECT * FROM tracks WHERE id IN (' + ','.join('?' for _ in ids) + ')', ids)
                if json.loads(row['rights']).get('status') == 'approved'}
        return [result[tid] for tid in ids if tid in result]

    def get_row(self, tid, request):
        with self.core.db() as conn:
            return dict(self.ns['track'](conn, tid, request))

    def block(self, tid):
        # Provider revocation: retained playlists/likes keep the ID, but the track
        # immediately leaves search and recommendation candidates.
        with self.core.db() as conn:
            row = conn.execute('SELECT rights FROM tracks WHERE id=?', (tid,)).fetchone()
            if row:
                rights = json.loads(row['rights'])
                if rights.get('source') == 'audius' and rights.get('status') == 'approved':
                    rights['status'] = 'unavailable'
                    conn.execute('UPDATE tracks SET rights=? WHERE id=?', (json.dumps(rights), tid))

    async def fresh(self, row):
        try:
            item = await self.provider.track(json.loads(row['rights'])['audius_id'])
            await asyncio.to_thread(self.publish, [item])
            return item
        except AudiusError as error:
            if error.status == 404:
                await asyncio.to_thread(self.block, row['id'])
            raise

    async def _search(self, query, offset, key):
        try:
            items = await self.provider.search(query, offset)
            await asyncio.to_thread(self.publish, items)
            value = ([item['id'] for item in items], '', time.monotonic() + 300)
        except (AudiusError, asyncio.TimeoutError):
            value = ([], 'Audius временно недоступен. Поиск в других источниках работает.', time.monotonic() + 20)
        except Exception:
            LOG.warning('Audius catalogue update failed', exc_info=True)
            value = ([], 'Не удалось обновить каталог Audius', time.monotonic() + 20)
        self.cached[key] = value
        self.cached.move_to_end(key)
        while len(self.cached) > 256:
            self.cached.popitem(last=False)
        return value

    async def search(self, query, offset=0, budget=1.25):
        query = ' '.join(query.split())[:200]
        key = (query.casefold(), offset)
        cached = self.cached.get(key)
        if cached and cached[2] > time.monotonic():
            return await asyncio.to_thread(self.rows, cached[0]), False, cached[1]
        task = self.pending.get(key)
        if task is None:
            if len(self.pending) >= 16:
                return [], False, 'Audius занят. Повтори поиск чуть позже.'
            task = asyncio.create_task(self._search(query, offset, key))
            self.pending[key] = task
            def finished(job):
                if self.pending.get(key) is job:
                    self.pending.pop(key, None)
            task.add_done_callback(finished)
        try:
            ids, message, _ = await asyncio.wait_for(asyncio.shield(task), budget)
            return await asyncio.to_thread(self.rows, ids), False, message
        except asyncio.TimeoutError:
            # Existing import clients retry search_pending; task is reused.
            return [], True, ''

    def discovery_queries(self, owner, seeds):
        # Use listener seeds plus genres of their own saved/played music, never
        # another account's history or a random global trending playlist.
        genres = Counter()
        with self.core.db() as conn:
            rows = conn.execute('''SELECT t.rights FROM tracks t WHERE t.id IN (
                SELECT track_id FROM likes WHERE user_id=? UNION
                SELECT track_id FROM listening_sessions WHERE user_id=? AND listened>=30
                  AND skipped=0 ORDER BY track_id LIMIT 300)''', (owner, owner))
            for row in rows:
                genre = json.loads(row['rights']).get('genre')
                if isinstance(genre, str) and genre.strip():
                    genres[genre.strip()] += 1
        queries = list(dict.fromkeys(str(seed).strip()[:200] for seed in seeds[:3] if str(seed).strip()))
        queries += [name for name, _ in genres.most_common(1) if name not in queries]
        return queries[:4]

    def schedule(self, account, seeds, excluded):
        if not self.enabled:
            return
        owner = str(account['user_id'])
        key = (owner, tuple(seeds[:3]))
        previous = self.discovery_state.get(key, (0, 0))
        if (owner in self.discovery_jobs or len(self.discovery_jobs) >= 16
                or previous[0] > time.monotonic()):
            return
        self.discovery_state[key] = (time.monotonic() + 90, (previous[1] + 30) % 300)
        self.discovery_state.move_to_end(key)
        while len(self.discovery_state) > 256:
            self.discovery_state.popitem(last=False)
        async def discover():
            try:
                queries = await asyncio.to_thread(self.discovery_queries, owner, seeds)
                for query in queries:
                    await self.search(query, previous[1], budget=12)
            except Exception:
                LOG.warning('Audius background discovery failed', exc_info=True)
        task = asyncio.create_task(discover())
        self.discovery_jobs[owner] = task
        def finished(job):
            if self.discovery_jobs.get(owner) is job:
                self.discovery_jobs.pop(owner, None)
        task.add_done_callback(finished)

    async def close(self):
        self.enabled = False
        jobs = list(self.discovery_jobs.values()) + list(self.pending.values())
        for job in jobs:
            job.cancel()
        if jobs:
            await asyncio.gather(*jobs, return_exceptions=True)


def install(ns, provider=None):
    app = ns['app']
    if getattr(app.state, 'nw_audius_service', None):
        return app.state.nw_audius_service
    service = AudiusCatalog(ns, provider)
    old_public = ns['public']

    def public(row):
        value = old_public(row)
        rights = json.loads(row['rights'])
        if rights.get('source') == 'audius':
            value.update(source='audius', source_url=rights.get('source_url'),
                         is_remote=not row['file'], downloadable=bool(rights.get('downloadable')),
                         cover_url='/api/covers/' + row['id'] if rights.get('artwork_url') else None)
        return value

    ns['public'] = public
    engine = getattr(app.state, 'nw_adaptive_wave_engine', None)
    if engine:
        engine.public = public

    route = next(r for r in app.router.routes if isinstance(r, APIRoute)
                 and r.path == '/api/tracks' and 'GET' in r.methods)
    original_search = route.endpoint
    # The provider-aware main handler owns the source policy. Replacing it with
    # the old additive wrapper dropped `provider` and started Audius even when
    # SoundCloud had already found the requested recording.
    if 'provider' not in inspect.signature(original_search).parameters:
        app.router.routes.remove(route)

        def item_source(item):
            source = str(item.get('source') or '').casefold()
            if source:
                return source
            if str(item.get('id', '')).startswith('audius_'):
                return 'audius'
            if str(item.get('source_url') or '').startswith('https://soundcloud.com/'):
                return 'soundcloud'
            return 'local'

        def relevant_primary(query, item):
            if item_source(item) != 'soundcloud':
                return False
            wanted = set(re.findall(r'[^\W_]+', query.casefold().replace('ё', 'е')))
            words = set(re.findall(r'[^\W_]+',
                (str(item.get('title') or '') + ' ' + str(item.get('artist') or '')).casefold().replace('ё', 'е')))
            return bool(wanted and wanted <= words)

        @app.get('/api/tracks')
        async def tracks(request: Request, q: str = '', provider: str = ''):
            provider = provider.strip().casefold()
            if provider not in ('', 'soundcloud', 'audius'):
                raise HTTPException(400, 'Неизвестный музыкальный источник')
            account = await call(ns['session'], request, False)
            query = q.strip()[:200]
            if not account or not query:
                return await call(original_search, request, q=q)
            if provider == 'audius':
                found, pending, message = await service.search(query)
                return {'tracks': found, 'search_pending': pending,
                        'search_retry_after': 1.5, 'audius_pending': pending,
                        'audius_message': message}
            try:
                result = await call(original_search, request, q=q)
            except HTTPException:
                raise
            except Exception:
                LOG.warning('Primary search failed before Audius fallback', exc_info=True)
                result = {'tracks': [], 'search_message': 'SoundCloud временно недоступен'}
            if not isinstance(result, dict):
                return result
            result = dict(result)
            primary = [item for item in result.get('tracks', [])
                       if item_source(item) != 'audius']
            result['tracks'] = primary
            if provider == 'soundcloud':
                result['tracks'] = [item for item in primary if item_source(item) == 'soundcloud']
                return result
            # Pending is not an empty completed search. Keep polling SoundCloud
            # before requesting the backup provider.
            if result.get('search_pending') or any(relevant_primary(query, item) for item in primary):
                return result
            found, pending, message = await service.search(query)
            combined = {item['id']: item for item in primary}
            combined.update({item['id']: item for item in found})
            # Source preference is explicit; each source keeps its own relevance
            # and stable upstream order. No artists or popularity are hardcoded.
            result['tracks'] = sorted(combined.values(), key=lambda item:
                ({'soundcloud': 0, 'audius': 1}.get(item_source(item), 2), relevance(query, item)))
            result['search_pending'] = bool(pending)
            if pending:
                result['search_retry_after'] = 1.5
            result['audius_message'] = message
            result['audius_pending'] = pending
            return result

    async def media(request, row):
        try:
            item = await service.fresh(row)
            response, client = await service.provider.audio(item['rights']['audius_id'], request.headers.get('range'))
        except AudiusError as error:
            raise HTTPException(error.status, str(error))
        async def close():
            await response.aclose()
            await client.aclose()
        content_type = response.headers.get('content-type', '').split(';')[0].lower()
        if response.status_code != 416 and content_type not in ('audio/mpeg', 'audio/mp3', 'audio/mp4', 'application/octet-stream'):
            await close()
            raise HTTPException(502, 'Audius не вернул аудиопоток')
        headers = {name: response.headers[name] for name in ('content-length', 'content-range', 'accept-ranges')
                   if name in response.headers}
        headers.update({'Cache-Control': 'private, no-store', 'X-NW-Audio-Source': 'audius'})
        if request.method == 'HEAD' or response.status_code == 416:
            await close()
            if response.status_code == 416:
                headers.pop('content-length', None)
            return Response(status_code=response.status_code, headers=headers, media_type=content_type or 'audio/mpeg')
        async def chunks():
            try:
                async for chunk in response.aiter_raw():
                    yield chunk
            finally:
                await close()
        return StreamingResponse(chunks(), status_code=response.status_code, headers=headers,
                                 media_type=content_type, background=BackgroundTask(close))

    async def cover(request, row):
        try:
            url = json.loads(row['rights']).get('artwork_url')
            if not url:
                raise HTTPException(404, 'Обложка недоступна')
            cached = service.covers.get(url)
            if not cached or cached[0] < time.monotonic():
                raw, mime = await asyncio.wait_for(service.provider.cover(url), 12)
                cached = (time.monotonic() + 3600, raw, mime)
                service.covers[url] = cached
                service.covers.move_to_end(url)
                while len(service.covers) > 32:
                    service.covers.popitem(last=False)
            return Response(cached[1], media_type=cached[2],
                            headers={'Cache-Control': 'private, max-age=3600', 'Vary': 'Cookie'})
        except asyncio.TimeoutError:
            raise HTTPException(504, 'Обложка временно недоступна')
        except AudiusError as error:
            raise HTTPException(error.status, str(error))

    # ASGI wrappers keep all original query/dependency handling for other sources.
    def wrap(original, kind):
        async def dispatch(scope, receive, send):
            request = Request(scope, receive)
            tid = scope.get('path_params', {}).get('tid', '')
            if not tid.startswith('audius_'):
                return await original(scope, receive, send)
            await call(ns['session'], request)
            row = await asyncio.to_thread(service.get_row, tid, request)
            if json.loads(row['rights']).get('source') != 'audius':
                return await original(scope, receive, send)
            if kind == 'offline':
                try:
                    item = await service.fresh(row)
                except AudiusError as error:
                    raise HTTPException(error.status, str(error))
                if not item['rights']['downloadable']:
                    raise HTTPException(403, 'Автор разрешил только прослушивание этого трека')
                return await original(scope, receive, send)
            response = await (media(request, row) if kind == 'media' else cover(request, row))
            return await response(scope, receive, send)
        return dispatch

    kinds = {'/api/stream/{tid}': 'media', '/api/covers/{tid}': 'cover',
             '/api/offline-export/{tid}': 'offline'}
    for route in app.router.routes:
        if isinstance(route, APIRoute) and route.path in kinds:
            route.app = wrap(route.app, kinds[route.path])

    @app.get('/api/audius/status')
    async def status(request: Request):
        await call(ns['session'], request)
        return {'version': VERSION, 'search': True, 'playlist_import': True,
                'wave': bool(getattr(app.state, 'nw_adaptive_wave_engine', None)),
                'active_searches': len(service.pending), 'active_discovery': len(service.discovery_jobs)}

    previous_lifespan = app.router.lifespan_context
    @asynccontextmanager
    async def lifespan(application):
        async with previous_lifespan(application) as state:
            service.enabled = True
            try:
                yield state
            finally:
                await service.close()
    app.router.lifespan_context = lifespan
    app.state.nw_audius_service = service
    return service
