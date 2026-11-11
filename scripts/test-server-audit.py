"""Offline regression tests for server-side Nightwell audit fixes."""
import asyncio
import os
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "server-updates" / "audio-quality"))
sys.path.insert(0, str(ROOT / "server-updates" / "playlist-transfer"))
sys.path.insert(0, str(ROOT / "server"))

from audio_quality import SoundCloudQuality
from lava_webhook import _record_event


class AudioQualitySingleFlightTests(unittest.IsolatedAsyncioTestCase):
    async def test_concurrent_quality_requests_share_one_upstream_call(self):
        service = SoundCloudQuality(None, lambda request: "tester")
        calls = 0

        async def simulated_lookup(request, owner, track_id, quality):
            nonlocal calls
            calls += 1
            await asyncio.sleep(0.025)
            return {"track_id": track_id, "quality": quality}

        service._selected_uncached = simulated_lookup
        results = await asyncio.gather(*(
            service.selected(None, "tester", "sc_101", "high")
            for _ in range(12)
        ))
        self.assertEqual(calls, 1)
        self.assertTrue(all(item == results[0] for item in results))
        self.assertEqual(service.inflight, {})


class LavaWebhookPersistenceTests(unittest.TestCase):
    def test_duplicate_webhook_does_not_duplicate_event(self):
        original = os.environ.get("NW_LAVA_DB")
        try:
            with tempfile.TemporaryDirectory() as tmp:
                os.environ["NW_LAVA_DB"] = str(Path(tmp) / "webhooks.sqlite3")
                _record_event("payment.success", "invoice_99",
                              '{"eventType":"payment.success"}', "event-key")
                _record_event("payment.success", "invoice_99",
                              '{"eventType":"payment.success"}', "event-key")
                with sqlite3.connect(os.environ["NW_LAVA_DB"]) as connection:
                    events = connection.execute(
                        "SELECT COUNT(*) FROM lava_events"
                    ).fetchone()[0]
                self.assertEqual(events, 1)
        finally:
            if original is None:
                os.environ.pop("NW_LAVA_DB", None)
            else:
                os.environ["NW_LAVA_DB"] = original


if __name__ == "__main__":
    unittest.main()
