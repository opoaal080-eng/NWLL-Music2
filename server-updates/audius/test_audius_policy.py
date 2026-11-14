"""Exercise the final ASGI routes after the optional Audius wrapper installs."""
import importlib.util
from pathlib import Path
import sys
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import patch

import httpx
from fastapi import FastAPI, Request
from fastapi.routing import APIRoute


def load_catalog():
    # No credentials/network/provider implementation is involved in these route
    # policy tests. Playback/provider methods remain unchanged from public history.
    provider = ModuleType('audius_provider')
    provider.AudiusClient = object
    provider.AudiusError = type('AudiusError', (Exception,), {})
    spec = importlib.util.spec_from_file_location(
        '_tested_audius_catalog', Path(__file__).with_name('audius_catalog.py'))
    module = importlib.util.module_from_spec(spec)
    with patch.dict(sys.modules, {'audius_provider': provider}):
        spec.loader.exec_module(module)
    return module


CATALOG = load_catalog()
SC = {'id': 'sc-original', 'title': 'Грустный дэнс (при уч. Артём Качер)',
      'artist': 'Artik & Anna Asti', 'source': 'soundcloud'}
AU = {'id': 'audius_backup', 'title': 'Грустный дэнс',
      'artist': 'Другой артист', 'source': 'audius'}


class WrapperPolicyTests(unittest.IsolatedAsyncioTestCase):
    def setup_app(self, *, provider_aware=False, payload=None):
        app = FastAPI()
        calls = []
        payload = payload if payload is not None else {'tracks': [SC], 'search_pending': False}

        async def session(request, required=True):
            return None if request.headers.get('x-test-guest') else {'user_id': 'account'}

        def public(row):
            return dict(row)

        if provider_aware:
            @app.get('/api/tracks')
            async def main(request: Request, q: str = '', provider: str = ''):
                calls.append(('main', q, provider))
                if provider == 'audius':
                    return {'tracks': [AU], 'handled_by': 'main'}
                return {**payload, 'handled_by': 'main'}
        else:
            @app.get('/api/tracks')
            async def main(request: Request, q: str = ''):
                calls.append(('main', q, ''))
                return payload

        @app.get('/api/wave')
        async def wave(request: Request):
            return {'tracks': [SC], 'recommendation_engine': 'adaptive-sc-primary'}

        @app.get('/api/recommendations')
        async def recommendations(request: Request):
            return {'tracks': [SC], 'recommendation_engine': 'adaptive-sc-primary'}

        app.state.nw_adaptive_wave_engine = SimpleNamespace(public=public)
        ns = {'app': app, 'core': SimpleNamespace(), 'public': public,
              'session': session, 'track': lambda *args: None}
        service = CATALOG.install(ns, provider=object())

        async def backup(query, offset=0, budget=1.25):
            calls.append(('audius', query, offset))
            return [AU], False, ''

        service.search = backup
        return app, service, calls, ns, main, wave, recommendations

    async def get(self, app, path='/api/tracks', **kwargs):
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app),
                                     base_url='http://nightwell.test') as client:
            return await client.get(path, **kwargs)

    async def test_late_wrapper_preserves_provider_aware_main_route(self):
        app, service, calls, ns, main, _, _ = self.setup_app(provider_aware=True)
        route = next(r for r in app.routes if isinstance(r, APIRoute) and r.path == '/api/tracks')
        self.assertIs(route.endpoint, main)
        for provider, identity in [('soundcloud', 'sc-original'), ('audius', 'audius_backup')]:
            response = await self.get(app, params={'q': 'грустный дэнс', 'provider': provider})
            self.assertEqual(response.status_code, 200)
            self.assertEqual(response.json()['tracks'][0]['id'], identity)
            self.assertEqual(response.json()['handled_by'], 'main')
        self.assertEqual([call[0] for call in calls], ['main', 'main'])
        self.assertIs(CATALOG.install(ns, provider=object()), service)
        self.assertEqual(sum(isinstance(r, APIRoute) and r.path == '/api/tracks'
                             for r in app.routes), 1)

    async def test_late_wrapper_leaves_wave_and_recommendation_policy_intact(self):
        app, _, _, _, _, wave, recommendations = self.setup_app(provider_aware=True)
        endpoints = {r.path: r.endpoint for r in app.routes if isinstance(r, APIRoute)}
        self.assertIs(endpoints['/api/wave'], wave)
        self.assertIs(endpoints['/api/recommendations'], recommendations)
        for path in ['/api/wave', '/api/recommendations']:
            response = await self.get(app, path)
            self.assertEqual(response.json()['tracks'], [SC])
            self.assertEqual(response.json()['recommendation_engine'], 'adaptive-sc-primary')

    async def test_legacy_main_search_uses_soundcloud_without_audius(self):
        app, _, calls, _, _, _, _ = self.setup_app()
        response = await self.get(app, params={'q': 'грустный дэнс'})
        self.assertEqual(response.json()['tracks'], [SC])
        self.assertEqual([call[0] for call in calls], ['main'])

    async def test_pending_primary_is_not_treated_as_empty_for_fallback(self):
        app, _, calls, _, _, _, _ = self.setup_app(payload={
            'tracks': [], 'search_pending': True, 'search_retry_after': 2})
        response = await self.get(app, params={'q': 'грустный дэнс'})
        self.assertTrue(response.json()['search_pending'])
        self.assertEqual([call[0] for call in calls], ['main'])

    async def test_empty_completed_primary_requests_backup_after_primary(self):
        app, _, calls, _, _, _, _ = self.setup_app(payload={
            'tracks': [], 'search_pending': False, 'soundcloud_message': 'Нет совпадений'})
        response = await self.get(app, params={'q': 'грустный дэнс'})
        self.assertEqual(response.json()['tracks'], [AU])
        self.assertEqual([call[0] for call in calls], ['main', 'audius'])
        self.assertEqual(response.json()['soundcloud_message'], 'Нет совпадений')

    async def test_legacy_explicit_source_selection_is_retained(self):
        for provider, expected_calls, result in [
            ('soundcloud', ['main'], [SC]), ('audius', ['audius'], [AU])]:
            app, _, calls, _, _, _, _ = self.setup_app()
            response = await self.get(app, params={'q': 'грустный дэнс', 'provider': provider})
            self.assertEqual(response.json()['tracks'], result)
            self.assertEqual([call[0] for call in calls], expected_calls)

    async def test_legacy_invalid_source_and_guest_do_not_query_audius(self):
        app, _, calls, _, _, _, _ = self.setup_app()
        invalid = await self.get(app, params={'q': 'Song', 'provider': 'unknown'})
        self.assertEqual(invalid.status_code, 400)
        self.assertEqual(calls, [])
        guest = await self.get(app, params={'q': 'Song'}, headers={'x-test-guest': '1'})
        self.assertEqual(guest.status_code, 200)
        self.assertEqual([call[0] for call in calls], ['main'])


if __name__ == '__main__':
    unittest.main()
