import unittest
from music_videos import normalized, choose_video, ClipLookup

class ClipTests(unittest.TestCase):
    def test_match_official_music_video(self):
        choices=[{"id":{"videoId":"AbCDef12345"},
                  "snippet":{"title":"Кино — Звезда (Official Music Video)",
                             "channelTitle":"Кино"}}]
        assert choose_video(choices,"Звезда","Кино")["video_id"]=="AbCDef12345"
    def test_reject_unrelated_and_remix(self):
        data=[{"id":{"videoId":"AbCDef12345"},
               "snippet":{"title":"Artist Song remix (Official Video)",
                          "channelTitle":"Artist"}}]
        assert choose_video(data,"Song","Artist") is None
        assert choose_video(data,"Different Song","Artist") is None
    def test_reject_bad_identifier_and_normalize(self):
        data=[{"id":{"videoId":"../../secret"},
               "snippet":{"title":"Artist - Song (Official Music Video)",
                          "channelTitle":"Artist"}}]
        assert choose_video(data,"Song","Artist") is None
        assert normalized("Ёлка — Трек")=="елка трек"

if __name__ == "__main__":
    unittest.main()
