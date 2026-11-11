import asyncio
import os
import tempfile
import unittest
from unittest import mock

from music_videos import normalized, choose_video, ClipLookup


class ClipTests(unittest.TestCase):
    def test_match_official_music_video(self):
        choices = [{
            "id": {"videoId": "AbCDef12345"},
            "snippet": {"title": "Кино — Звезда (Official Music Video)",
                        "channelTitle": "Кино"},
        }]
        self.assertEqual(
            choose_video(choices, "Звезда", "Кино")["video_id"],
            "AbCDef12345"
        )

    def test_reject_unrelated_and_remix(self):
        data = [{
            "id": {"videoId": "AbCDef12345"},
            "snippet": {"title": "Artist Song remix (Official Video)",
                        "channelTitle": "Artist"},
        }]
        self.assertIsNone(choose_video(data, "Song", "Artist"))
        self.assertIsNone(choose_video(data, "Different Song", "Artist"))

    def test_reject_bad_identifier_and_normalize(self):
        data = [{
            "id": {"videoId": "../../secret"},
            "snippet": {"title": "Artist - Song (Official Music Video)",
                        "channelTitle": "Artist"},
        }]
        self.assertIsNone(choose_video(data, "Song", "Artist"))
        self.assertEqual(normalized("Ёлка — Трек"), "елка трек")

    def test_verified_clip_survives_server_restart(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "clips.json")
            result = {"available": True, "video_id": "AbCDef12345",
                      "title": "Artist - Song", "channel": "Artist"}
            with mock.patch.dict(os.environ, {
                    "NW_YOUTUBE_API_KEY": "test-key",
                    "NW_YOUTUBE_CACHE_PATH": path}):
                finder = ClipLookup()
                with mock.patch.object(finder, "search_sync", return_value=result) as search:
                    self.assertEqual(asyncio.run(finder.lookup("Song", "Artist")), result)
                    self.assertEqual(search.call_count, 1)
                self.assertTrue(os.path.isfile(path))
                next_process = ClipLookup()
                with mock.patch.object(next_process, "search_sync",
                                       side_effect=AssertionError("must use verified cache")):
                    self.assertEqual(asyncio.run(next_process.lookup("Song", "Artist")), result)

    def test_no_application_side_search_limit(self):
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.dict(os.environ, {
                    "NW_YOUTUBE_API_KEY": "test-key",
                    "NW_YOUTUBE_CACHE_PATH": os.path.join(directory, "clips.json")}):
                finder = ClipLookup()
                result = {"available": True, "video_id": "AbCDef12345"}
                with mock.patch.object(finder, "search_sync", return_value=result) as search:
                    for i in range(95):
                        found = asyncio.run(finder.lookup(f"Song {i}", "Artist"))
                        self.assertTrue(found["available"])
                    self.assertEqual(search.call_count, 95)


if __name__ == "__main__":
    unittest.main()
