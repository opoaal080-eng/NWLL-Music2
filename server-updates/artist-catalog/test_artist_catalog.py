import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
MODULE = Path(__file__).with_name("artist_catalog.py")
spec = importlib.util.spec_from_file_location("artist_catalog", MODULE)
catalog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(catalog)


class ArtistDirectoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.db = Path(self.temp.name) / "catalog.db"
        self.images = Path(self.temp.name) / "images.json"
        self.directory = catalog.ArtistDirectory(
            self.db, image_map=self.images, image_hosts={"cdn.nightwell.test"}
        )
        self.owner = self.directory.owner_key("user-1")
        self.other = self.directory.owner_key("user-2")
        self.tracks = [
            {"id": "a", "title": "Сон", "artist": "Первый feat. Второй",
             "cover_url": "https://example.com/cover.jpg", "duration": 123.2},
            {"id": "b", "title": "Дождь", "artist": "Первый"},
            {"id": "c", "title": "Ночь", "artist": "Третий & Первый"},
        ]

    def test_feat_split_and_exact_membership(self):
        self.assertEqual(catalog.split_artists("Первый feat. Второй"), ["Первый", "Второй"])
        self.assertEqual(catalog.split_artists("Третий & Первый"), ["Третий", "Первый"])
        self.assertEqual(catalog.split_artists("А, а"), ["А"])

    def test_search_profile_and_correct_track_ids(self):
        self.assertEqual(self.directory.record(self.owner, self.tracks), 3)
        self.assertEqual([a["name"] for a in self.directory.search(self.owner, "пер")], ["Первый"])
        p = self.directory.profile(self.owner, "первый")
        self.assertEqual(p["total"], 3)
        self.assertEqual({x["id"] for x in p["tracks"]}, {"a", "b", "c"})

    def test_account_isolation(self):
        self.directory.record(self.owner, self.tracks)
        self.assertEqual(self.directory.search(self.other, "пер"), [])
        self.assertIsNone(self.directory.profile(self.other, "Первый"))

    def test_update_replaces_old_artist_links(self):
        self.directory.record(self.owner, self.tracks)
        self.directory.record(self.owner, [{"id": "a", "title": "Сон", "artist": "Новый"}])
        self.assertIsNone(self.directory.profile(self.owner, "Второй"))
        self.assertEqual(self.directory.profile(self.owner, "Новый")["total"], 1)

    def test_cloud_images_require_https_and_allowed_host(self):
        self.directory.record(self.owner, self.tracks)
        self.images.write_text(json.dumps({
            "Первый": "https://cdn.nightwell.test/artists/first.webp",
            "Второй": "https://evil.example/bad.webp",
        }, ensure_ascii=False), encoding="utf-8")
        self.assertEqual(
            self.directory.profile(self.owner, "Первый")["artist"]["image_url"],
            "https://cdn.nightwell.test/artists/first.webp",
        )
        self.assertIsNone(self.directory.profile(self.owner, "Второй")["artist"]["image_url"])
        self.assertIsNone(catalog.safe_image_url("http://cdn.nightwell.test/a", {"cdn.nightwell.test"}))
        self.assertIsNone(catalog.safe_image_url("https://cdn.nightwell.test.evil.example/a",
                                                  {"cdn.nightwell.test"}))

    def test_insecure_metadata_not_reindexed(self):
        self.directory.record(self.owner, [dict(
            self.tracks[0], email="private@example.com", api_key="super-secret")])
        profile = self.directory.profile(self.owner, "Первый")
        self.assertEqual(len(profile["tracks"]), 1)
        self.assertNotIn("email", profile["tracks"][0])
        self.assertNotIn("api_key", profile["tracks"][0])

    def test_remote_uploader_does_not_become_artist(self):
        uploaded = [
            {"id": "remote-1", "title": "Настоящий артист — Настоящая песня",
             "artist": "unrelated_uploader_189", "source": "soundcloud", "is_remote": True},
            {"id": "remote-2", "title": "Название без автора",
             "artist": "random_poster", "source": "soundcloud", "is_remote": True},
            {"id": "remote-3", "title": "Новая песня",
             "artist": "release-uploader", "source": "soundcloud", "is_remote": True,
             "performer": "Подписанный артист"},
        ]
        self.assertEqual(self.directory.record(self.owner, uploaded), 3)
        self.assertEqual(self.directory.search(self.owner, "unrelated"), [])
        self.assertEqual([x["name"] for x in self.directory.search(self.owner, "random")],
                         ["random_poster"])
        self.assertEqual(self.directory.search(self.owner, "настоящ"), [
            self.directory.profile(self.owner, "Настоящий артист")["artist"]])
        artist_tracks = self.directory.profile(self.owner, "Настоящий артист")["tracks"]
        self.assertEqual(artist_tracks[0]["artist"], "Настоящий артист")
        self.assertEqual(artist_tracks[0]["title"], "Настоящая песня")
        self.assertEqual(artist_tracks[0]["uploader"], "unrelated_uploader_189")
        self.assertEqual(self.directory.profile(self.owner, "Подписанный артист")["total"], 1)

    def test_query_limit_and_missing(self):
        self.directory.record(self.owner, self.tracks)
        self.assertEqual(self.directory.search(self.owner, "not present"), [])
        self.assertIsNone(self.directory.profile(self.owner, "not present"))


if __name__ == "__main__":
    unittest.main()
