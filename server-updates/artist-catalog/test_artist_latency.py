"""Wall-clock and coalescing regressions; only local fake catalogue requests."""
import asyncio
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import httpx
from fastapi import FastAPI, Request

sys.path.insert(0, str(Path(__file__).resolve().parent))
import artist_catalog as catalog


class ArtistLatencyTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.app = FastAPI()
        self.gate = asyncio.Event()
        self.entered = asyncio.Event()
        self.calls = []
        self.headers = {"authorization": "Bearer owner-a", "x-nw-device-token": "private-device-key"}
        self.track = {"id": "one", "title": "Song", "artist": "Artist"}
        self.reply = [self.track]

        @self.app.get("/api/tracks")
        async def tracks(request: Request):
            self.calls.append(dict(request.headers))
            self.entered.set()
            await self.gate.wait()
            return {"tracks": self.reply}

        def identity(request):
            return request.headers.get("authorization", "").removeprefix("Bearer ") or None

        self.directory = catalog.install(self.app, identity, Path(self.temp.name) / "artists.sqlite3")
        self.client = httpx.AsyncClient(transport=httpx.ASGITransport(app=self.app), base_url="https://nightwell.test")
        self.owner = self.directory.owner_key("owner-a")

    async def asyncTearDown(self):
        for task in list(self.directory._refresh_tasks.values()):
            task.cancel()
        await asyncio.gather(*list(self.directory._refresh_tasks.values()), return_exceptions=True)
        await self.client.aclose()

    async def test_warm_profile_and_search_do_not_wait_for_provider(self):
        self.directory.record(self.owner, [self.track])
        for path in ("/api/artists/profile?name=Artist", "/api/artists?q=Artist"):
            response = await asyncio.wait_for(self.client.get(path, headers=self.headers), 0.4)
            self.assertEqual(response.status_code, 200, response.text)
        await asyncio.wait_for(self.entered.wait(), 0.4)
        self.assertFalse(self.gate.is_set(), "Response must be usable before the provider finishes")

    async def test_cold_profile_has_hard_asgi_deadline(self):
        with patch.object(catalog, "ARTIST_REFRESH_TIMEOUT_SECONDS", 0.04):
            response = await asyncio.wait_for(self.client.get("/api/artists/profile?name=Artist", headers=self.headers), 0.5)
        self.assertEqual(response.status_code, 503, response.text)
        self.assertTrue(self.entered.is_set())

    async def test_concurrent_profile_misses_share_lookup_and_credentials(self):
        headers = dict(self.headers, **{"x-unrelated-secret": "must-not-forward"})
        requests = [asyncio.create_task(self.client.get("/api/artists/profile?name=Artist", headers=headers)) for _ in range(5)]
        await asyncio.wait_for(self.entered.wait(), 0.4)
        await asyncio.sleep(0.02)
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.calls[0].get("authorization"), self.headers["authorization"])
        self.assertEqual(self.calls[0].get("x-nw-device-token"), self.headers["x-nw-device-token"])
        self.assertNotIn("x-unrelated-secret", self.calls[0])
        self.gate.set()
        results = await asyncio.wait_for(asyncio.gather(*requests), 0.8)
        self.assertTrue(all(result.status_code == 200 for result in results))
        self.assertEqual(len(self.calls), 1)

    async def test_cached_profile_is_not_shared_between_accounts(self):
        self.directory.record(self.owner, [self.track])
        self.reply = []
        self.gate.set()
        response = await self.client.get("/api/artists/profile?name=Artist", headers={"authorization": "Bearer owner-b"})
        self.assertEqual(response.status_code, 404, response.text)
        self.assertEqual(self.directory.profile(self.owner, "Artist")["tracks"][0]["id"], "one")
