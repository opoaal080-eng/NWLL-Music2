"""Audius public read API. Credentials/cookies from Nightwell never leave it.

Metadata is fetched from a fixed official API. Media URLs may originate only
in that API's responses; each redirect is checked before opening it.
"""
import asyncio
from collections import OrderedDict
import ipaddress
import math
import os
import re
import socket
import time
from urllib.parse import urljoin, urlsplit

import httpx

API = 'https://api.audius.co/v1'
ID = re.compile(r'^[A-Za-z0-9]{1,40}$')
MAX_JSON = 4 * 1024 * 1024


class AudiusError(Exception):
    def __init__(self, message='Audius временно недоступен', status=502):
        super().__init__(message)
        self.status = status


def clean(value, limit=300):
    return ' '.join(value.split())[:limit] if isinstance(value, str) else ''


def valid_https(url):
    try:
        p = urlsplit(url)
        host = (p.hostname or '').lower()
        if (p.scheme != 'https' or not host or p.username or p.password
                or p.port not in (None, 443) or p.fragment or len(url) > 8192
                or any(c.isspace() or ord(c) < 32 for c in url)
                or host == 'localhost' or host.endswith(('.localhost', '.local', '.internal'))):
            return False
        try:
            return ipaddress.ip_address(host).is_global
        except ValueError:
            return '.' in host
    except (ValueError, TypeError):
        return False


async def public_destination(url):
    if not valid_https(url):
        raise AudiusError('Некорректный адрес медиа Audius')
    try:
        addresses = await asyncio.wait_for(asyncio.to_thread(
            socket.getaddrinfo, urlsplit(url).hostname, 443, type=socket.SOCK_STREAM), 3)
        if not addresses or any(not ipaddress.ip_address(a[4][0]).is_global for a in addresses):
            raise AudiusError('Недопустимый адрес медиа Audius')
    except (OSError, asyncio.TimeoutError) as error:
        raise AudiusError() from error


def normalize(raw):
    """Accept public, full-length, ungated streams only, with stable IDs."""
    if not isinstance(raw, dict) or not isinstance(raw.get('id'), str) or not ID.fullmatch(raw['id']):
        return None
    if raw.get('is_streamable') is not True or raw.get('is_available') is False:
        return None
    if any(raw.get(k) for k in ('is_delete', 'is_unlisted', 'is_stream_gated',
                               'is_scheduled_release', 'stream_conditions', 'allowed_api_keys')):
        return None
    access = raw.get('access') or {}
    if not isinstance(access, dict) or access.get('stream') is False:
        return None
    title = clean(raw.get('title'))
    user = raw.get('user') or {}
    if not isinstance(user, dict):
        return None
    artist = clean(user.get('name')) or clean(user.get('handle'))
    duration = raw.get('duration')
    if (not title or not artist or isinstance(duration, bool) or not isinstance(duration, (int, float))
            or not math.isfinite(duration) or not 1 <= duration <= 86400):
        return None
    # Preserve composite titles: import/ranker already parse real artist credits.
    artwork = raw.get('artwork') or {}
    cover = next((artwork.get(k) for k in ('480x480', '150x150', '1000x1000')
                  if valid_https(artwork.get(k))), None) if isinstance(artwork, dict) else None
    permalink = raw.get('permalink')
    source_url = urljoin('https://audius.co', permalink) if isinstance(permalink, str) else ''
    if not valid_https(source_url) or urlsplit(source_url).hostname != 'audius.co':
        source_url = 'https://audius.co/' + str(user.get('handle') or '')
    downloadable = (raw.get('is_downloadable') is True and not raw.get('is_download_gated')
                    and not raw.get('download_conditions') and access.get('download') is not False)
    return {'id': 'audius_' + raw['id'], 'title': title, 'artist': artist,
            'album': '', 'duration': float(duration), 'file': '', 'color': '#777777', 'cover': '',
            'rights': {'status': 'approved', 'source': 'audius', 'audius_id': raw['id'],
                       'source_url': source_url, 'artwork_url': cover,
                       'genre': clean(raw.get('genre'), 80), 'mood': clean(raw.get('mood'), 80),
                       'tags': clean(raw.get('tags'), 1000), 'isrc': clean(raw.get('isrc'), 40),
                       'downloadable': bool(downloadable), 'checked_at': time.time()}}


class AudiusClient:
    def __init__(self, transport=None, validator=public_destination):
        self.transport, self.validator = transport, validator
        self.slots = asyncio.Semaphore(2)
        self.rate_lock = asyncio.Lock()
        self.next_request = 0.0
        self.backoff = 0.0
        self.metadata = OrderedDict()

    def client(self):
        return httpx.AsyncClient(transport=self.transport, timeout=httpx.Timeout(12, connect=4),
                                 follow_redirects=False, headers={'User-Agent': 'NightwellMusic/1.0',
                                                               'Accept-Encoding': 'identity'})

    def params(self, params=None):
        result = {'app_name': 'NightwellMusic', **(params or {})}
        key = os.environ.get('NW_AUDIUS_API_KEY', '').strip()
        if key:
            result['api_key'] = key
        return result

    async def get_json(self, path, params=None):
        if time.monotonic() < self.backoff:
            raise AudiusError('Audius ограничил запросы. Повторим позже', 503)
        async with self.slots:
            async with self.rate_lock:
                await asyncio.sleep(max(0, self.next_request - time.monotonic()))
                self.next_request = time.monotonic() + .35
            try:
                async with self.client() as client:
                    async with client.stream('GET', API + path, params=self.params(params)) as response:
                        if response.status_code == 429:
                            try:
                                delay = float(response.headers.get('retry-after', '30'))
                            except ValueError:
                                delay = 30
                            self.backoff = time.monotonic() + min(300, max(10, delay))
                            raise AudiusError('Audius ограничил запросы. Повторим позже', 503)
                        if response.status_code != 200:
                            raise AudiusError('Трек Audius недоступен' if response.status_code in (403,404) else 'Audius временно недоступен',
                                              404 if response.status_code in (403,404) else 502)
                        chunks, size = [], 0
                        async for part in response.aiter_bytes():
                            size += len(part)
                            if size > MAX_JSON:
                                raise AudiusError('Слишком большой ответ Audius')
                            chunks.append(part)
                import json
                payload = json.loads(b''.join(chunks))
                if not isinstance(payload, dict) or 'data' not in payload:
                    raise AudiusError('Некорректный ответ Audius')
                return payload['data']
            except (httpx.HTTPError, ValueError) as error:
                raise AudiusError() from error

    async def search(self, query, offset=0):
        raw = await asyncio.wait_for(self.get_json('/tracks/search', {
            'query': query[:200], 'limit': 30, 'offset': offset,
            'sort_method': 'relevant', 'includePurchaseable': 'false'}), 9)
        if not isinstance(raw, list):
            raise AudiusError('Некорректный список Audius')
        return [item for entry in raw[:30] if (item := normalize(entry)) is not None]

    async def track(self, track_id):
        if not ID.fullmatch(track_id):
            raise AudiusError('Трек не найден', 404)
        cached = self.metadata.get(track_id)
        if cached and cached[0] > time.monotonic():
            return cached[1]
        try:
            raw = await asyncio.wait_for(self.get_json('/tracks/' + track_id), 9)
        except asyncio.TimeoutError as error:
            raise AudiusError() from error
        item = normalize(raw)
        if item is None or item['rights']['audius_id'] != track_id:
            raise AudiusError('Трек Audius больше не доступен для воспроизведения', 404)
        self.metadata[track_id] = (time.monotonic() + 60, item)
        self.metadata.move_to_end(track_id)
        while len(self.metadata) > 256:
            self.metadata.popitem(last=False)
        return item

    async def open_media(self, url, range_header=None, params=None):
        """Return an open response + client; caller must close both on disconnect."""
        if range_header and not re.fullmatch(r'bytes=(?:\d+-\d*|-\d+)', range_header):
            raise AudiusError('Недопустимый диапазон', 416)
        client = self.client()
        response = None
        try:
            for _ in range(6):
                await self.validator(url)
                headers = {'Range': range_header} if range_header else {}
                request = client.build_request('GET', url, headers=headers, params=params)
                response = await client.send(request, stream=True)
                # API key is sent only to the official API, never to a redirect.
                params = None
                if response.status_code in (301,302,303,307,308):
                    location = response.headers.get('location')
                    await response.aclose()
                    if not location:
                        raise AudiusError('Audius не вернул адрес потока')
                    url = urljoin(str(response.url), location)
                    continue
                if response.status_code not in (200,206,416):
                    raise AudiusError('Трек Audius недоступен', 404 if response.status_code in (403,404) else 502)
                return response, client
            raise AudiusError('Слишком много перенаправлений Audius')
        except BaseException:
            if response is not None:
                await response.aclose()
            await client.aclose()
            raise

    async def audio(self, track_id, range_header=None):
        try:
            return await asyncio.wait_for(self.open_media(
                API + '/tracks/' + track_id + '/stream', range_header,
                self.params()), 18)
        except (httpx.HTTPError, asyncio.TimeoutError) as error:
            raise AudiusError() from error

    async def cover(self, url):
        response = client = None
        try:
            response, client = await self.open_media(url)
            chunks, size = [], 0
            async for part in response.aiter_bytes():
                size += len(part)
                if size > 5 * 1024 * 1024:
                    raise AudiusError('Слишком большая обложка', 404)
                chunks.append(part)
            raw = b''.join(chunks)
            mime = ('image/jpeg' if raw.startswith(b'\xff\xd8\xff') else
                    'image/png' if raw.startswith(b'\x89PNG\r\n\x1a\n') else
                    'image/webp' if raw[:4] == b'RIFF' and raw[8:12] == b'WEBP' else None)
            if not mime:
                raise AudiusError('Обложка недоступна', 404)
            return raw, mime
        except httpx.HTTPError as error:
            raise AudiusError('Обложка недоступна', 404) from error
        finally:
            if response is not None:
                await response.aclose()
            if client is not None:
                await client.aclose()
