import asyncio
import copy
import json
import time

import httpx
import pytest
from audius_provider import AudiusClient, AudiusError, normalize, public_destination, valid_https


def raw_track(**updates):
    return {'id': 'abc12', 'title': 'Song', 'user': {'name': 'Artist'}, 'duration': 180,
            'is_streamable': True, 'is_available': True, 'access': {'stream': True, 'download': True},
            'is_downloadable': True, 'genre': 'Electronic', 'mood': 'Peaceful', 'tags': 'ambient,chill',
            'permalink': '/artist/song', 'artwork': {'480x480': 'https://cdn.audius.co/cover.jpg'}, **updates}


@pytest.mark.parametrize('updates', [
    {'is_streamable': False}, {'is_streamable': None}, {'is_available': False},
    {'is_stream_gated': True}, {'stream_conditions': {'follow_user_id': 12}},
    {'access': {'stream': False}}, {'allowed_api_keys': ['someone']},
    {'is_delete': True}, {'is_unlisted': True}, {'is_scheduled_release': True},
    {'duration': float('nan')}, {'duration': -1}, {'id': '../x'}, {'id': 123}, {'title': ''}, {'user': None},
])
def test_unplayable_or_malformed_never_enter_catalog(updates):
    assert normalize(raw_track(**updates)) is None


def test_mapping_stable_ids_and_download_permission():
    mapped = normalize(raw_track(is_download_gated=True))
    assert mapped['id'] == 'audius_abc12'
    assert mapped['rights']['downloadable'] is False
    assert mapped['rights']['genre'] == 'Electronic'
    assert mapped['rights']['source_url'] == 'https://audius.co/artist/song'
    assert mapped['rights']['artwork_url'].endswith('cover.jpg')
    assert normalize(raw_track(is_downloadable=False))['rights']['downloadable'] is False


@pytest.mark.parametrize('url', ['http://audius.co/a', 'https://127.0.0.1/a',
    'https://[::1]/a', 'https://169.254.169.254/a', 'https://a.local/a',
    'https://audius.co@localhost/a', 'https://user:pass@audius.co/a',
    'https://audius.co:22/a', 'file:///tmp/a', 'https://audius.co/\nheader'])
def test_private_or_unsafe_urls_rejected(url):
    assert not valid_https(url)


@pytest.mark.asyncio
async def test_private_dns_answer_rejected(monkeypatch):
    import socket
    monkeypatch.setattr(socket, 'getaddrinfo', lambda *a, **kw: [(2,1,6,'',('192.168.0.1',443))])
    with pytest.raises(AudiusError):
        await public_destination('https://cdn.audius.co/cover.jpg')


async def fake_validator(url):
    if not valid_https(url):
        raise AudiusError('unsafe URL')


@pytest.mark.asyncio
async def test_query_credentials_and_rate_limit(monkeypatch):
    seen = []
    async def handle(request):
        seen.append(request)
        return httpx.Response(429, headers={'Retry-After': '40'})
    monkeypatch.setenv('NW_AUDIUS_API_KEY', 'test-app-key')
    client = AudiusClient(httpx.MockTransport(handle), fake_validator)
    with pytest.raises(AudiusError):
        await client.search('Кино Звезда')
    assert seen[0].url.params['query'] == 'Кино Звезда'
    assert seen[0].url.params['api_key'] == 'test-app-key'
    assert client.backoff > time.monotonic() + 35
    with pytest.raises(AudiusError):
        await client.search('other')
    assert len(seen) == 1


@pytest.mark.asyncio
async def test_stream_range_redirect_no_key_or_cookie_leak(monkeypatch):
    seen = []
    async def handle(request):
        seen.append(request)
        if request.url.host == 'api.audius.co':
            return httpx.Response(302, headers={'Location': 'https://cdn.audius.co/audio.mp3'})
        return httpx.Response(206, content=b'audio', headers={'Content-Type': 'audio/mpeg', 'Content-Range': 'bytes 5-9/100'})
    monkeypatch.setenv('NW_AUDIUS_API_KEY', 'test-app-key')
    client = AudiusClient(httpx.MockTransport(handle), fake_validator)
    response, session = await client.audio('abc12', 'bytes=5-9')
    try:
        assert await response.aread() == b'audio'
        assert seen[0].url.params['api_key'] == 'test-app-key'
        assert not seen[1].url.query
        assert all(r.headers['range'] == 'bytes=5-9' for r in seen)
        assert all('cookie' not in r.headers and 'authorization' not in r.headers for r in seen)
    finally:
        await response.aclose()
        await session.aclose()


@pytest.mark.asyncio
async def test_redirect_to_local_service_not_followed():
    calls = []
    async def handle(request):
        calls.append(request)
        return httpx.Response(302, headers={'Location': 'https://127.0.0.1/admin'})
    client = AudiusClient(httpx.MockTransport(handle), fake_validator)
    with pytest.raises(AudiusError):
        await client.audio('abc12')
    assert len(calls) == 1


@pytest.mark.asyncio
async def test_html_cover_rejected():
    client = AudiusClient(httpx.MockTransport(lambda r: httpx.Response(200, content=b'<html>not image</html>')), fake_validator)
    with pytest.raises(AudiusError):
        await client.cover('https://cdn.audius.co/cover.jpg')
