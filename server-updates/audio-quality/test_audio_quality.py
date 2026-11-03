"""Deterministic tests: SoundCloud AAC variants, notice, fallback, auth and URL policy."""
import importlib.util
import tempfile
import unittest
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.testclient import TestClient

spec = importlib.util.spec_from_file_location(
    "audio_quality", Path(__file__).with_name("audio_quality.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

HI = "https://playback.media-streaming.soundcloud.cloud/audio/aac_160/playlist.m3u8?sig=a"
LOW = "https://playback.media-streaming.soundcloud.cloud/audio/aac_96/playlist.m3u8?sig=b"

class QualityTests(unittest.TestCase):
    def setUp(self):
        self.app = FastAPI()
        self.track = {"id": "one", "source": "soundcloud", "soundcloud_urn": "soundcloud:tracks:12"}
        self.available = {"hls_aac_160_url": HI, "hls_aac_96_url": LOW}

        def identity(request: Request):
            return request.headers.get("x-account")

        async def track_provider(request, track_id):
            return self.track if track_id == "one" else None

        async def streams_provider(track, token):
            return self.available

        self.service = module.install(
            self.app, identity, track_provider=track_provider,
            token_provider=lambda: "mock-token", streams_provider=streams_provider)
        self.client = TestClient(self.app, follow_redirects=False)
        self.headers = {"x-account": "my-nightwell-account"}

    def info(self, quality):
        # Clear service cache when test changes stream variants.
        self.service.cached.clear()
        return self.client.get("/api/audio-quality/options?track_id=one&quality="+quality,
                               headers=self.headers)

    def test_exact_96_and_160(self):
        low=self.info("economy").json()
        self.assertEqual(low["selected_quality"], "economy")
        self.assertEqual(low["actual_kbps"], 96)
        self.assertFalse(low["fallback"])
        self.assertEqual(low["source"], "soundcloud")
        high=self.info("high").json()
        self.assertEqual(high["selected_quality"], "high")
        self.assertEqual(high["actual_kbps"], 160)
        self.assertFalse(high["fallback"])
        self.assertEqual(self.info("auto").json()["actual_kbps"], 160)

    def test_fallback_notifies_and_streams_available_quality(self):
        self.available = {"hls_aac_160_url": HI}
        info=self.info("economy").json()
        self.assertTrue(info["fallback"])
        self.assertEqual(info["actual_kbps"], 160)
        self.assertIn("недоступно", info["message"])
        response=self.client.get(
            "/api/audio-quality/stream/one?quality=economy", headers=self.headers)
        self.assertEqual(response.status_code, 307)
        self.assertEqual(response.headers["location"], HI)
        self.assertEqual(response.headers["x-nw-audio-quality"], "high")
        self.available = {"hls_aac_96_url": LOW}
        info=self.info("high").json()
        self.assertTrue(info["fallback"])
        self.assertEqual(info["actual_kbps"], 96)
        self.assertEqual(self.client.get(
            "/api/audio-quality/stream/one?quality=high", headers=self.headers
        ).headers["location"], LOW)

    def test_blocked_or_unavailable_falls_back_to_original(self):
        self.available = {}
        response=self.info("high").json()
        self.assertEqual(response["selected_quality"], "original")
        self.assertIsNone(response["actual_kbps"])
        self.assertTrue(response["message"])
        original=self.client.get("/api/audio-quality/stream/one?quality=high",
                                  headers=self.headers)
        self.assertEqual(original.headers["location"],
                         "/api/stream/one?cache=1&format=hls")
        self.assertEqual(original.headers["x-nw-audio-quality"], "original")

    def test_unsafe_media_urls_are_ignored(self):
        for url in ("http://evil.example/test.m3u8",
                    "https://evil.example/track.m3u8",
                    "https://127.0.0.1/track.m3u8",
                    "https://playback.media-streaming.soundcloud.cloud.evil.example/track.m3u8"):
            self.available={"hls_aac_160_url":url}
            self.assertIsNone(self.info("high").json()["actual_kbps"])

    def test_identity_and_source_validation(self):
        self.assertEqual(self.client.get("/api/audio-quality/options").status_code, 401)
        self.assertEqual(self.client.get(
            "/api/audio-quality/options?track_id=one&quality=high",
            headers=self.headers).status_code, 200)
        self.assertEqual(self.client.get(
            "/api/audio-quality/stream/one?quality=ultra",
            headers=self.headers).status_code, 400)
        self.track["source"]="local"
        self.track.pop("soundcloud_urn")
        self.assertEqual(self.info("high").json()["source"],"original")
        self.assertFalse(module.permitted_soundcloud_permalink("https://localhost/private"))
        self.assertTrue(module.permitted_soundcloud_permalink(
            "https://soundcloud.com/someone/a-track"))

    def test_unknown_track_does_not_trigger_source(self):
        response=self.client.get("/api/audio-quality/options?track_id=missing&quality=high",
                                 headers=self.headers).json()
        self.assertEqual(response["selected_quality"],"original")
        self.assertIn("не найден", response["message"])

if __name__ == "__main__":
    unittest.main()
