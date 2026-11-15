"""Async regressions for bounded, coalesced optional quality negotiation.

No real source calls, threads or wall-clock sleeps of seconds are required.
Successful cached media metadata never substitutes for fresh track permission.
"""
import asyncio
import importlib.util
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from fastapi import FastAPI, Request

spec = importlib.util.spec_from_file_location(
    "audio_quality_performance_target", Path(__file__).with_name("audio_quality.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

HIGH = "https://playback.media-streaming.soundcloud.cloud/audio/aac_160/playlist.m3u8?sig=high"
LOW = "https://playback.media-streaming.soundcloud.cloud/audio/aac_96/playlist.m3u8?sig=low"
TRACK = {"id": "one", "source": "soundcloud", "soundcloud_urn": "soundcloud:tracks:12"}


class QualityPerformanceTests(unittest.IsolatedAsyncioTestCase):
    def service(self, *, tracks=None, tokens=None, streams=None):
        async def default_tracks(request, track_id):
            return dict(TRACK) if track_id == "one" else None

        async def default_streams(track, token):
            return {"hls_aac_160_url": HIGH, "hls_aac_96_url": LOW}

        return module.SoundCloudQuality(
            FastAPI(), lambda request: "alice", track_provider=tracks or default_tracks,
            token_provider=tokens or (lambda: "test-token"), streams_provider=streams or default_streams)

    async def selected(self, service, owner="alice", quality="high"):
        return await asyncio.wait_for(service.selected(None, owner, "one", quality), timeout=0.75)

    async def test_catalogue_subrequest_preserves_only_session_credentials(self):
        app = FastAPI()
        observed = {}

        @app.get("/api/tracks")
        async def catalogue(request: Request):
            observed.update(dict(request.headers))
            return {"tracks": [dict(TRACK)]}

        headers = {
            "cookie": "session=verified-session",
            "authorization": "Bearer verified-access-token",
            "x-csrf-token": "csrf-token",
            "origin": "https://nightwell.test",
            "x-nw-device-token": "verified-device-token",
            "x-nw-device-id": "ios_test_device_1234",
            "x-nw-device-platform": "ios",
            "x-user-id": "untrusted-owner-override",
            "x-unrelated-secret": "must-not-be-forwarded",
        }
        request = Request({
            "type": "http", "method": "GET", "scheme": "https",
            "path": "/api/audio-quality/options", "query_string": b"",
            "headers": [(key.encode(), value.encode()) for key, value in headers.items()],
            "server": ("nightwell.test", 443), "client": ("127.0.0.1", 1234),
        })
        service = module.SoundCloudQuality(app, lambda request: "alice")
        track = await asyncio.wait_for(service.track_for(request, "one"), 0.75)
        self.assertEqual(track["id"], "one")
        for name in ("cookie", "authorization", "x-csrf-token", "origin",
                     "x-nw-device-token", "x-nw-device-id", "x-nw-device-platform"):
            self.assertEqual(observed.get(name), headers[name], name)
        self.assertNotIn("x-user-id", observed)
        self.assertNotIn("x-unrelated-secret", observed)

    async def test_slow_catalogue_has_real_deadline(self):
        cancelled = asyncio.Event()

        async def tracks(request, track_id):
            try:
                await asyncio.Event().wait()
            finally:
                cancelled.set()

        service = self.service(tracks=tracks)
        with patch.object(module, "TRACK_LOOKUP_TIMEOUT_SECONDS", 0.03):
            started = time.monotonic()
            result = await self.selected(service)
        self.assertLess(time.monotonic() - started, 0.5)
        self.assertEqual(result["selected_quality"], "original")
        self.assertIsNone(result["stream_url"])
        self.assertTrue(cancelled.is_set(), "Timed-out catalogue work must be cancelled")

    async def test_token_and_source_chain_have_one_resolution_deadline(self):
        stream_calls = 0

        async def tokens():
            await asyncio.Event().wait()

        async def streams(track, token):
            nonlocal stream_calls
            stream_calls += 1
            return {"hls_aac_160_url": HIGH}

        service = self.service(tokens=tokens, streams=streams)
        with patch.object(module, "RESOLUTION_TIMEOUT_SECONDS", 0.03):
            started = time.monotonic()
            result = await self.selected(service)
        self.assertLess(time.monotonic() - started, 0.5)
        self.assertEqual(result["selected_quality"], "original")
        self.assertIsNone(result["actual_kbps"])
        self.assertEqual(stream_calls, 0)

    async def test_token_plus_source_share_one_total_deadline(self):
        async def tokens():
            await asyncio.sleep(0.025)
            return "test-token"

        async def streams(track, token):
            await asyncio.sleep(0.025)
            return {"hls_aac_160_url": HIGH}

        service = self.service(tokens=tokens, streams=streams)
        with patch.object(module, "RESOLUTION_TIMEOUT_SECONDS", 0.04):
            result = await self.selected(service)
        self.assertEqual(result["selected_quality"], "original")
        self.assertIsNone(result["stream_url"])

    async def test_parallel_qualities_share_one_source_resolution(self):
        calls = 0
        started = asyncio.Event()
        release = asyncio.Event()

        async def streams(track, token):
            nonlocal calls
            calls += 1
            started.set()
            await release.wait()
            return {"hls_aac_160_url": HIGH, "hls_aac_96_url": LOW}

        service = self.service(streams=streams)
        tasks = [asyncio.create_task(self.selected(service, quality=quality))
                 for quality in ("auto", "high", "economy")]
        try:
            await asyncio.wait_for(started.wait(), 0.5)
            await asyncio.sleep(0.015)
            release.set()
            results = await asyncio.gather(*tasks)
        finally:
            release.set()
            for task in tasks:
                if not task.done():
                    task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
        self.assertEqual(calls, 1)
        self.assertEqual([result["selected_quality"] for result in results], ["high", "high", "economy"])
        self.assertEqual([result["actual_kbps"] for result in results], [160, 160, 96])

    async def test_cancelling_one_waiter_keeps_shared_resolution_alive(self):
        calls = 0
        started = asyncio.Event()
        release = asyncio.Event()
        source_cancelled = asyncio.Event()

        async def streams(track, token):
            nonlocal calls
            calls += 1
            started.set()
            try:
                await release.wait()
            except asyncio.CancelledError:
                source_cancelled.set()
                raise
            return {"hls_aac_160_url": HIGH}

        service = self.service(streams=streams)
        first = asyncio.create_task(self.selected(service, quality="auto"))
        second = asyncio.create_task(self.selected(service, quality="high"))
        try:
            await asyncio.wait_for(started.wait(), 0.5)
            await asyncio.sleep(0.015)
            first.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await first
            release.set()
            result = await second
        finally:
            release.set()
            for task in (first, second):
                if not task.done():
                    task.cancel()
            await asyncio.gather(first, second, return_exceptions=True)
        self.assertFalse(source_cancelled.is_set())
        self.assertEqual(calls, 1)
        self.assertEqual(result["stream_url"], HIGH)

    async def test_cached_url_does_not_bypass_revoked_catalogue_access(self):
        permitted = True
        catalogue_checks = 0

        async def tracks(request, track_id):
            nonlocal catalogue_checks
            catalogue_checks += 1
            return dict(TRACK) if permitted else None

        service = self.service(tracks=tracks)
        first = await self.selected(service)
        self.assertEqual(first["stream_url"], HIGH)
        permitted = False
        second = await self.selected(service)
        self.assertGreaterEqual(catalogue_checks, 2)
        self.assertIsNone(second["stream_url"])
        self.assertEqual(second["selected_quality"], "original")

    async def test_different_accounts_never_share_source_resolution(self):
        calls = 0

        async def streams(track, token):
            nonlocal calls
            calls += 1
            await asyncio.sleep(0)
            return {"hls_aac_160_url": HIGH}

        service = self.service(streams=streams)
        results = await asyncio.gather(self.selected(service, owner="alice"),
                                       self.selected(service, owner="bob"))
        self.assertEqual(calls, 2)
        self.assertTrue(all(result["stream_url"] == HIGH for result in results))

    async def test_immediate_retries_do_not_repeat_failed_source_lookup(self):
        calls = 0

        async def streams(track, token):
            nonlocal calls
            calls += 1
            return {}

        service = self.service(streams=streams)
        first = await self.selected(service, quality="auto")
        second = await self.selected(service, quality="high")
        self.assertEqual(calls, 1)
        self.assertEqual(first["selected_quality"], "original")
        self.assertEqual(second["selected_quality"], "original")


if __name__ == "__main__":
    unittest.main()
