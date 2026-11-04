"""Tests for per-account artist preferences and personalized wave."""
import importlib.util
import tempfile
import unittest
from pathlib import Path

import httpx
from fastapi import FastAPI, Request

spec=importlib.util.spec_from_file_location("nw_wave_artists",Path(__file__).with_name("wave_artists.py"))
module=importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class FavoriteArtistsTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.app=FastAPI()
        @self.app.get("/api/tracks")
        async def tracks(q:str=""):
            return {"tracks":[
                {"id":"a","title":"Народная песня","artist":"Надежда Кадышева"},
                {"id":"b","title":"Песня","artist":"Другой исполнитель"}]}
        @self.app.get("/api/wave")
        async def wave():
            return {"tracks":[
                {"id":"b","title":"Песня","artist":"Другой исполнитель"},
                {"id":"a","title":"Народная песня","artist":"Надежда Кадышева"}]}
        module.install(self.app,lambda r:r.cookies.get("account"),Path(self.temp.name)/"taste.db")
        self.client=httpx.AsyncClient(transport=httpx.ASGITransport(app=self.app),
                                      base_url="http://test",cookies={"account":"alice"})
    async def asyncTearDown(self):
        await self.client.aclose()
        self.temp.cleanup()
    async def test_private_selection_and_wave(self):
        r=await self.client.get("/api/wave-artists/preferences")
        self.assertEqual(r.status_code,200)
        self.assertFalse(r.json()["configured"])
        r=await self.client.put("/api/wave-artists/preferences",json={"artists":["Надежда Кадышева"]})
        self.assertEqual(r.status_code,200)
        self.assertTrue(r.json()["configured"])
        self.assertEqual(r.json()["artists"],["Надежда Кадышева"])
        mix=await self.client.get("/api/wave-artists/mix")
        self.assertEqual(mix.status_code,200)
        self.assertEqual(mix.json()["tracks"][0]["id"],"a")
        other=await self.client.get("/api/wave-artists/preferences",cookies={"account":"bob"})
        self.assertFalse(other.json()["configured"])
    async def test_suggestions_and_validation(self):
        r=await self.client.get("/api/wave-artists/suggestions")
        self.assertEqual(r.status_code,200)
        self.assertTrue(any(x["name"]=="Надежда Кадышева" for x in r.json()["artists"]))
        invalid=await self.client.put("/api/wave-artists/preferences",
                                      json={"artists":["x"]})
        self.assertEqual(invalid.status_code,400)

if __name__=="__main__":
    unittest.main()
