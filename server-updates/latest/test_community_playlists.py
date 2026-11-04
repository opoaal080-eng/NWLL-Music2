"""Integration checks for opt-in community playlist publication."""
import importlib.util
import tempfile
import unittest
from pathlib import Path

import httpx
from fastapi import FastAPI, HTTPException, Request

spec = importlib.util.spec_from_file_location(
    "nw_community", Path(__file__).with_name("community_playlists.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class CommunityPlaylistTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        app = FastAPI()
        library = {
            "alice": {"alice_mix": {
                "name": "Советские песни",
                "tracks": [
                    {"id": "track1", "title": "Песня", "artist": "Ансамбль",
                     "cover_url": "https://covers.test/a.jpg", "source_url": "secret-url"},
                    {"id": "local_private", "title": "Домашняя запись",
                     "artist": "Локально", "_offline": True}
                ]
            }},
            "bob": {}
        }

        def owner(request):
            return request.cookies.get("account")

        @app.get("/api/playlists")
        async def list_own(request: Request):
            uid = owner(request)
            if not uid:
                raise HTTPException(401)
            return {"playlists": [{"id": k, "name": p["name"]}
                                  for k, p in library.setdefault(uid, {}).items()]}

        @app.get("/api/playlists/{pid}/tracks")
        async def get_tracks(pid: str, request: Request):
            user = owner(request)
            if pid not in library.setdefault(user, {}):
                raise HTTPException(404)
            return {"tracks": library[user][pid]["tracks"]}

        @app.post("/api/playlists")
        async def create(request: Request):
            uid = owner(request)
            if not uid:
                raise HTTPException(401)
            payload = await request.json()
            pid = "copy" + str(len(library.setdefault(uid, {})) + 1)
            library[uid][pid] = {"name": payload["name"], "tracks": []}
            return {"id": pid, "name": payload["name"]}

        @app.post("/api/playlists/{pid}/tracks/{tid}")
        async def add_track(pid: str, tid: str, request: Request):
            uid = owner(request)
            if pid not in library.setdefault(uid, {}):
                raise HTTPException(404)
            library[uid][pid]["tracks"].append({"id": tid})
            return {"ok": True}

        @app.delete("/api/playlists/{pid}")
        async def delete_playlist(pid: str, request: Request):
            library.setdefault(owner(request), {}).pop(pid, None)
            return {"ok": True}

        module.install(app, owner, Path(self.temp.name) / "public.sqlite3")
        self.client = httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="https://music.test")
        self.library = library

    async def asyncTearDown(self):
        await self.client.aclose()

    async def test_private_by_default_publish_find_save_unpublish(self):
        self.client.cookies.set("account", "bob")
        empty = await self.client.get("/api/community-playlists?q=Советские")
        self.assertEqual(empty.json()["playlists"], [])
        forbidden = await self.client.post("/api/community-playlists/publish",
                                           json={"playlist_id": "alice_mix"})
        self.assertEqual(forbidden.status_code, 404)

        self.client.cookies.set("account", "alice")
        published = await self.client.post("/api/community-playlists/publish",
                                           json={"playlist_id": "alice_mix"})
        self.assertEqual(published.status_code, 200, published.text)
        public_id = published.json()["id"]
        mine = await self.client.get("/api/community-playlists/mine")
        self.assertEqual(mine.json()["playlists"][0]["source_playlist_id"], "alice_mix")
        found = await self.client.get("/api/community-playlists?q=советские")
        self.assertEqual(found.json()["playlists"][0]["id"], public_id)
        detail = await self.client.get("/api/community-playlists/" + public_id)
        tracks = detail.json()["playlist"]["tracks"]
        self.assertEqual([t["id"] for t in tracks], ["track1"])
        self.assertNotIn("source_url", tracks[0])
        self.assertEqual((await self.client.get("/api/community-playlists?q=%25"))
                         .json()["playlists"], [])

        self.client.cookies.set("account", "bob")
        denied = await self.client.delete("/api/community-playlists/publish/alice_mix")
        self.assertEqual(denied.status_code, 404)
        saved = await self.client.post("/api/community-playlists/" + public_id + "/save")
        self.assertEqual(saved.status_code, 200, saved.text)
        self.assertEqual(self.library["bob"][saved.json()["id"]]["tracks"], [{"id": "track1"}])

        self.client.cookies.set("account", "alice")
        removed = await self.client.delete("/api/community-playlists/publish/alice_mix")
        self.assertEqual(removed.status_code, 200)
        gone = await self.client.get("/api/community-playlists/" + public_id)
        self.assertEqual(gone.status_code, 404)

    async def test_anonymous_cannot_publish(self):
        result = await self.client.post("/api/community-playlists/publish",
                                        json={"playlist_id": "alice_mix"})
        self.assertEqual(result.status_code, 401)


if __name__ == "__main__":
    unittest.main()
