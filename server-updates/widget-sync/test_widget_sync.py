"""Contract tests for private Nightwell WidgetKit account pairing."""
import asyncio
import base64
import importlib.util
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest

import httpx
from fastapi import FastAPI

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from widget_sync import install
from install_widget_sync import patch


class WidgetSyncTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.database = Path(self.temp.name) / "widget.sqlite3"
        self.app = FastAPI()
        install(self.app,
                identity=lambda req: req.headers.get("x-test-owner"),
                db_path=self.database,
                csrf_verifier=lambda req: req.headers.get("x-test-csrf") == "valid")
        self.client = httpx.AsyncClient(transport=httpx.ASGITransport(app=self.app),
                                        base_url="https://example.test")
        self.auth = {"x-test-owner": "alice", "x-test-csrf": "valid"}

    async def asyncTearDown(self):
        await self.client.aclose()
        self.temp.cleanup()

    async def paired(self):
        result = await self.client.post("/api/widgets/pair-code", headers=self.auth)
        self.assertEqual(result.status_code, 200, result.text)
        self.assertIn("no-store", result.headers["cache-control"])
        code = result.json()["code"]
        self.assertEqual(len(code.replace("-", "")), 16)
        response = await self.client.post("/api/widgets/pair", json={"code": code})
        self.assertEqual(response.status_code, 200, response.text)
        token = response.json()["token"]
        self.assertGreaterEqual(len(token), 36)
        return code, token

    async def test_pairing_is_one_use_and_scoped(self):
        self.assertEqual((await self.client.post("/api/widgets/pair-code")).status_code, 401)
        self.assertEqual((await self.client.post("/api/widgets/pair-code",
                headers={"x-test-owner": "alice"})).status_code, 403)
        code, token = await self.paired()
        self.assertEqual((await self.client.post("/api/widgets/pair",
                json={"code": code})).status_code, 401)
        self.assertEqual((await self.client.get("/api/widgets/state")).status_code, 401)
        self.assertEqual((await self.client.get("/api/widgets/state",
                headers={"Authorization": "Bearer " + token})).status_code, 200)
        self.assertEqual((await self.client.get("/api/widgets/state",
                headers={"Authorization": "Bearer " + token[:-1] + "x"})).status_code, 401)

    async def test_state_artwork_and_revocation(self):
        code, token = await self.paired()
        bearer = {"Authorization": "Bearer " + token}
        self.assertEqual((await self.client.post("/api/widgets/state",
                headers={"x-test-owner": "alice"}, json={"track_id": "test"})).status_code, 403)
        track = {"track_id": "song-12", "title": "A song", "artist": "A singer", "playing": True}
        response = await self.client.post("/api/widgets/state", json=track, headers=self.auth)
        self.assertEqual(response.status_code, 200, response.text)
        state = await self.client.get("/api/widgets/state", headers=bearer)
        self.assertEqual(state.json()["title"], "A song")
        self.assertTrue(state.json()["playing"])
        self.assertFalse(state.json()["has_cover"])
        image = base64.b64encode(b"\xff\xd8\xff" + b"x" * 120).decode()
        response = await self.client.post("/api/widgets/cover", headers=self.auth,
                        json={"track_id": "song-12", "jpeg": image})
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual((await self.client.get("/api/widgets/cover", headers=bearer)).content,
                         b"\xff\xd8\xff" + b"x" * 120)
        # A different account cannot overwrite this user's state.
        bob = dict(self.auth, **{"x-test-owner": "bob"})
        await self.client.post("/api/widgets/state", json={"track_id": "elsewhere",
             "title": "Other", "artist": "B", "playing": True}, headers=bob)
        self.assertEqual((await self.client.get("/api/widgets/state",
              headers=bearer)).json()["title"], "A song")
        changed = dict(track, track_id="song-13")
        self.assertEqual((await self.client.post("/api/widgets/state",
              headers=self.auth, json=changed)).status_code, 200)
        self.assertEqual((await self.client.get("/api/widgets/cover",headers=bearer)).status_code,404)
        response = await self.client.post("/api/widgets/revoke-all",
                                          headers=self.auth, json={})
        self.assertEqual(response.status_code, 200)
        self.assertEqual((await self.client.get("/api/widgets/state", headers=bearer)).status_code,401)

    async def test_expired_code_denied_and_no_token_leak(self):
        response = await self.client.post("/api/widgets/pair-code", headers=self.auth)
        code = response.json()["code"].replace("-", "")
        with sqlite3.connect(self.database) as db:
            db.execute("UPDATE nw_widget_pairs SET expires=0")
        self.assertEqual((await self.client.post("/api/widgets/pair",
                          json={"code":code})).status_code,401)
        _, token = await self.paired()
        with sqlite3.connect(self.database) as db:
            values = db.execute("SELECT digest FROM nw_widget_tokens").fetchall()
        self.assertTrue(values)
        self.assertNotIn(token, [v[0] for v in values])

    async def test_invalid_artwork_rejected(self):
        _, token = await self.paired()
        await self.client.post("/api/widgets/state", headers=self.auth,
            json={"track_id": "song", "title": "Title", "artist": "Artist", "playing": True})
        bad = base64.b64encode(b"NOT A JPEG" * 15).decode()
        self.assertEqual((await self.client.post("/api/widgets/cover",
           headers=self.auth,json={"track_id":"song","jpeg":bad})).status_code,400)
        self.assertEqual((await self.client.post("/api/widgets/cover",
           headers=self.auth,json={"track_id":"old","jpeg":bad})).status_code,400)


class WidgetInstallerTests(unittest.TestCase):
    def test_patch_idempotent_and_requires_csrf(self):
        template = ("from pathlib import Path\nfrom fastapi import FastAPI\n"
                    "app = FastAPI()\ndef identity(request): return 'alice'\n"
                    "def premium_csrf(request): return True\n"
                    "if __name__ == '__main__': pass\n")
        changed = patch(template)
        self.assertIn("_nw_install_widget_sync(", changed)
        self.assertEqual(patch(changed), changed)
        with self.assertRaises(RuntimeError):
            patch("from fastapi import FastAPI\napp=FastAPI()\n")


if __name__ == "__main__":
    unittest.main()
