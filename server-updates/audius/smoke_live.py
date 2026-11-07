"""Opt-in live smoke test: read-only API, one short audio range, no account."""
import asyncio
import json
from audius_provider import AudiusClient


async def main():
    provider = AudiusClient()
    tracks = await provider.search('deadmau5')
    assert tracks, 'Audius returned no public tracks'
    track = await provider.track(tracks[0]['rights']['audius_id'])
    response, client = await provider.audio(track['rights']['audius_id'], 'bytes=0-65535')
    try:
        size = 0
        prefix = b''
        async for chunk in response.aiter_bytes():
            prefix = (prefix + chunk)[:16]
            size += len(chunk)
            if size >= 65536:
                break
        assert response.status_code == 206, 'Upstream did not honor Range'
        assert size and response.headers.get('content-type', '').startswith('audio/'), 'Not an audio stream'
        assert prefix.startswith(b'ID3') or prefix[:1] == b'\xff', 'Not an MP3 frame/header'
        print(json.dumps({'search_results': len(tracks), 'track_id': track['id'],
                          'audio_status': response.status_code, 'audio_bytes': size,
                          'content_range': response.headers.get('content-range')}, ensure_ascii=False))
    finally:
        await response.aclose()
        await client.aclose()
    if track['rights'].get('artwork_url'):
        data, mime = await asyncio.wait_for(provider.cover(track['rights']['artwork_url']), 15)
        print(json.dumps({'cover_bytes': len(data), 'cover_type': mime}))


if __name__ == '__main__':
    asyncio.run(main())
