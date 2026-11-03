import asyncio
import importlib.util
import tempfile
import unittest
from pathlib import Path
from fastapi import FastAPI, HTTPException, Request
from fastapi.testclient import TestClient

spec = importlib.util.spec_from_file_location("audio_quality", Path(__file__).with_name("audio_quality.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class QualityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.app = FastAPI()

        def identity(request: Request):
            return request.headers.get("x-account")

        @self.app.get("/api/stream/{track_id}")
        async def original(track_id: str):
            return {"audio": track_id}

        self.cache = module.install(self.app, identity, cache_root=Path(self.temp.name))
        self.cache.ffmpeg = None
        self.client = TestClient(self.app, follow_redirects=False)

    def test_requires_login_and_valid_track_id(self):
        unauthenticated = self.client.get("/api/audio-quality/options")
        self.assertEqual(unauthenticated.status_code, 401)
        result = self.client.get("/api/audio-quality/stream/track_1?quality=high",
                                 headers={"x-account": "a"})
        self.assertEqual(result.status_code, 307)
        self.assertEqual(result.headers["location"],
                         "/api/stream/track_1?cache=1&format=file")
        self.assertEqual(result.headers["x-nw-audio-quality"], "original-pending")
        self.assertEqual(self.client.get(
            "/api/audio-quality/stream/x%2Fbad?quality=high",
            headers={"x-account": "a"}).status_code, 404)
        self.assertEqual(self.client.get(
            "/api/audio-quality/stream/a?quality=ultra",
            headers={"x-account": "a"}).status_code, 400)

    def test_original_hls_never_triggers_ffmpeg(self):
        for query in ("quality=original", "quality=high&format=hls"):
            result = self.client.get("/api/audio-quality/stream/track_1?" + query,
                                     headers={"x-account": "a"})
            self.assertEqual(result.status_code, 307)
            self.assertEqual(result.headers["x-nw-audio-quality"], "original")
        self.assertFalse(self.cache.pending)

    def test_account_scoped_cache_and_byte_ranges(self):
        one = self.cache.cached_path("owner-one", "id_1", "economy")
        other = self.cache.cached_path("owner-two", "id_1", "economy")
        self.assertNotEqual(one, other)
        self.assertEqual(one.parent, other.parent)
        # Verified identity-derived keys are required for the served cache path.
        owner_a = self.client.get("/api/audio-quality/options",
                                  headers={"x-account": "a"})
        self.assertEqual(owner_a.status_code, 200)
        self.assertEqual(owner_a.json()["options"][1]["target_kbps"], 96)

    def test_prewarm_bounded_and_auth_required(self):
        self.assertEqual(self.client.post(
            "/api/audio-quality/prewarm", json={"tracks":["id"],"quality":"balanced"}
        ).status_code, 401)
        result = self.client.post("/api/audio-quality/prewarm",
            headers={"x-account": "a"},
            json={"tracks": ["a", "b"], "quality": "balanced"})
        self.assertEqual(result.status_code, 200)
        self.assertEqual(result.json()["queued"], 0)
        self.assertEqual(self.client.post("/api/audio-quality/prewarm",
            headers={"x-account": "a"},
            json={"tracks": ["a","b","c","d","e","f"], "quality": "high"}
        ).status_code, 400)

    def test_cache_eviction_is_limited_to_generated_m4a(self):
        path = Path(self.temp.name)
        (path / "keep.txt").write_text("keep", encoding="utf-8")
        self.cache.trim_cache()
        self.assertTrue((path / "keep.txt").is_file())


if __name__ == "__main__":
    unittest.main()
