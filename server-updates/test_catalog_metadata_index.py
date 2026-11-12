import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from catalog_metadata_index import (
    fetch_json, job_state, norm, open_db, parse_track,
    run_offset_job, search_tracks, upsert_page,
)


class MetadataIndexTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.db = open_db(str(Path(self.folder.name) / "catalog.sqlite"))

    def tearDown(self):
        self.db.close()
        self.folder.cleanup()

    def test_normalizes_russian_and_latin(self):
        self.assertEqual(norm("Ёж — Песня!"), "ezh pesnya")

    def test_audius_insert_search_and_update(self):
        item = {"id": "A12", "title": "Звезда", "artist_name": "Кино",
                "duration": 250, "artwork": {"150x150": "https://example.test/c"}}
        self.assertEqual(upsert_page(self.db, "audius", [item],
                                     "audius:latest", "1", False), 1)
        self.assertEqual(search_tracks(self.db, "Кино Звезда")[0]["source_id"], "A12")
        item["title"] = "Звезда (Live)"
        self.assertEqual(upsert_page(self.db, "audius", [item],
                                     "audius:latest", "2", True), 0)
        self.assertEqual(search_tracks(self.db, "Звезда Live")[0]["title"], "Звезда (Live)")
        self.assertEqual(job_state(self.db, "audius:latest"), ("2", True))

    def test_soundcloud_duration_is_milliseconds(self):
        item = {"id": 2, "title": "Song", "duration": 180000,
                "user": {"username": "Artist"}, "permalink_url": "https://soundcloud.com/x/y"}
        track = parse_track("soundcloud", item)
        self.assertEqual(track[3], 180.0)

    def test_broader_query_fallback(self):
        upsert_page(self.db, "audius", [
            {"id": "a", "title": "Blood Group", "artist_name": "Kino", "duration": 270}
        ], "test", "1", True)
        self.assertEqual(search_tracks(self.db, "Kino Blood Group Official", 5)[0]["source_id"], "a")

    def test_resume_pagination(self):
        args = SimpleNamespace(page_size=2, max_pages=1, max_tracks=10, delay=0.3)
        pages = [
            {"data": [{"id": "1", "title": "One", "artist_name": "A"},
                      {"id": "2", "title": "Two", "artist_name": "A"}]},
            {"data": [{"id": "3", "title": "Three", "artist_name": "A"}]},
        ]
        with patch("catalog_metadata_index.fetch_json", side_effect=pages) as fetch:
            run_offset_job(self.db, "audius:latest", "audius", "/tracks/latest", {}, None, args)
            self.assertEqual(job_state(self.db, "audius:latest"), ("2", False))
            run_offset_job(self.db, "audius:latest", "audius", "/tracks/latest", {}, None, args)
            self.assertEqual(job_state(self.db, "audius:latest"), ("3", True))
            self.assertIn("offset=2", fetch.call_args_list[1].args[0])

    def test_url_allowlist(self):
        with self.assertRaises(ValueError):
            fetch_json("http://api.audius.co/v1/tracks/latest", delay=0.3)
        with self.assertRaises(ValueError):
            fetch_json("https://example.com/", delay=0.3)


if __name__ == "__main__":
    unittest.main()
