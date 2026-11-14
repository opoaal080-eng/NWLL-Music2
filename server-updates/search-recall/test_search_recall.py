"""Regression tests for the real search route, without importing server settings.

The fixture contains only the supplied search and recommendation functions. Provider traffic,
authentication and the database are isolated; no credentials or uploaded server
configuration are needed to run this suite.
"""
import ast
import asyncio
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import tempfile
import sys
import threading
import time
from types import SimpleNamespace
import unicodedata
import unittest
from unittest.mock import patch

import search_recall_install as installer


FIXTURE = Path(__file__).with_name("fixture_search_routes.py.txt").read_text()
TITLE = "грустный дэнс"


def track(ident, title, artist, source):
    return {"id": ident, "title": title, "artist": artist, "album": "", "duration": 180,
            "rights": json.dumps({"status": "approved", "source": source})}


class RouteHarness:
    def __init__(self, source, *, authenticated=True, audius=None, soundcloud=None,
                 progress=None, message="", audius_error=None, soundcloud_configured=True,
                 audius_configured=True, cached=None):
        self.db = sqlite3.connect(":memory:")
        self.db.row_factory = sqlite3.Row
        self.db.execute("CREATE TABLE tracks(id TEXT PRIMARY KEY,title TEXT,artist TEXT,album TEXT,rights TEXT)")
        self.authenticated = authenticated
        self.audius = audius or []
        self.soundcloud = soundcloud or []
        self.progress = progress or {}
        self.message = message
        self.audius_calls = []
        self.soundcloud_calls = []
        self.provider_order = []

        def store(_db, rows):
            for row in rows:
                self.db.execute("INSERT OR REPLACE INTO tracks VALUES(?,?,?,?,?)",
                                tuple(row[k] for k in ("id", "title", "artist", "album", "rights")))
            self.db.commit()

        def audius_search(query, limit):
            self.audius_calls.append((query, limit))
            self.provider_order.append("audius")
            if audius_error is not None:
                raise audius_error
            return self.audius

        async def sc_search(account, seeds, *, search=False, search_state=None):
            self.soundcloud_calls.append((account, seeds, search))
            self.provider_order.append("soundcloud")
            store(None, self.soundcloud)
            search_state.update(self.progress)
            search_state["ranked_ids"] = [row["id"] for row in self.soundcloud]
            return {row["id"] for row in self.soundcloud}, self.message

        async def threadpool(func, *args):
            return func(*args)

        def fail(code, detail):
            raise ValueError((code, detail))

        namespace = {
            "Request": object,
            "asyncio": SimpleNamespace(wait_for=asyncio.wait_for, to_thread=threadpool,
                                       TimeoutError=asyncio.TimeoutError),
            "json": json, "re": re,
            "unicodedata": unicodedata, "core": SimpleNamespace(db=lambda: self.db),
            "session": lambda *_: {"user_id": "test-account"} if authenticated else None,
            "audius_provider": SimpleNamespace(configured=lambda: audius_configured, search_tracks=audius_search),
            "audius_bridge": SimpleNamespace(store_tracks=store),
            "sc": SimpleNamespace(configured=lambda: soundcloud_configured), "discover_soundcloud": sc_search,
            "run_in_threadpool": threadpool, "public": dict, "fail": fail,
        }
        tree = ast.parse(source)
        functions = [node for node in tree.body
                     if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
                     and node.name in ("search_text", "tracks")]
        for node in functions:
            node.decorator_list = []
        exec(compile(ast.Module(body=functions, type_ignores=[]), "<isolated search route>", "exec"), namespace)
        self.route = namespace["tracks"]
        store(None, cached or [])

    async def query(self, text=TITLE, provider=""):
        return await self.route(None, q=text, provider=provider)

    def close(self):
        self.db.close()


class SearchRouteTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.harnesses = []
        self.audius = track("audius-other", "Грустный дэнс", "INSTASAMKA", "audius")
        self.original = track("soundcloud-original", "Грустный дэнс (при уч. Артём Качер)",
                              "Artik & Anna Asti", "soundcloud")

    def tearDown(self):
        for harness in self.harnesses:
            harness.close()

    def harness(self, source=None, **kwargs):
        harness = RouteHarness(source or installer.patch(FIXTURE), **kwargs)
        self.harnesses.append(harness)
        return harness

    async def test_original_route_suppresses_soundcloud_after_other_artist_hit(self):
        harness = self.harness(FIXTURE, audius=[self.audius], soundcloud=[self.original])
        result = await harness.query()
        self.assertEqual(harness.soundcloud_calls, [])
        self.assertEqual([row["id"] for row in result["tracks"]], ["audius-other"])

    async def test_screenshot_original_is_retrieved_despite_exact_audius_distractor(self):
        harness = self.harness(audius=[self.audius], soundcloud=[self.original], cached=[self.audius])
        result = await harness.query()
        self.assertEqual(harness.audius_calls, [])
        self.assertEqual(len(harness.soundcloud_calls), 1)
        self.assertTrue(harness.soundcloud_calls[0][2])
        self.assertEqual(result["tracks"][0]["id"], "soundcloud-original")
        self.assertEqual([row["id"] for row in result["tracks"]], ["soundcloud-original"])
        self.assertNotIn("ranked_ids", result)

    async def test_soundcloud_upstream_order_beats_alphabetic_artist_and_exact_suffix(self):
        cover = track("soundcloud-cover", "Грустный дэнс", "AAAA cover uploader", "soundcloud")
        harness = self.harness(soundcloud=[self.original, cover])
        result = await harness.query()
        self.assertEqual([row["id"] for row in result["tracks"]],
                         ["soundcloud-original", "soundcloud-cover"])

    async def test_relevance_precedes_provider_preference(self):
        unrelated = track("audius-partial", "Дэнс ремиксы", "Грустный загрузчик", "audius")
        harness = self.harness(audius=[unrelated], soundcloud=[self.original])
        result = await harness.query()
        self.assertEqual(result["tracks"][0]["id"], "soundcloud-original")

    async def test_unrelated_primary_result_does_not_bury_relevant_fallback(self):
        wrong = track("soundcloud-unrelated", "Совсем другая песня", "Другой исполнитель", "soundcloud")
        harness = self.harness(audius=[self.audius], soundcloud=[wrong])
        result = await harness.query()
        self.assertEqual(len(harness.audius_calls), 1)
        self.assertEqual(result["tracks"][0]["id"], "audius-other")

    async def test_soundcloud_hit_suppresses_cached_audius_even_for_closer_title(self):
        partial = track("soundcloud-partial", "Грустный дэнс клубные хиты 2026",
                        "SoundCloud uploader", "soundcloud")
        harness = self.harness(audius=[self.audius], soundcloud=[partial], cached=[self.audius])
        result = await harness.query()
        self.assertEqual([row["id"] for row in result["tracks"]], ["soundcloud-partial"])
        self.assertEqual(harness.audius_calls, [])

    async def test_explicit_provider_filters_and_discovery_remain_respected(self):
        for provider in ("audius", "soundcloud"):
            with self.subTest(provider=provider):
                harness = self.harness(audius=[self.audius], soundcloud=[self.original])
                result = await harness.query(provider=provider)
                self.assertEqual(bool(harness.audius_calls), provider == "audius")
                self.assertEqual(bool(harness.soundcloud_calls), provider == "soundcloud")
                self.assertTrue(result["tracks"])
                self.assertTrue(all(json.loads(row["rights"])["source"] == provider
                                    for row in result["tracks"]))

    async def test_guest_never_triggers_remote_search_or_sees_approved_catalogue(self):
        harness = self.harness(authenticated=False, audius=[self.audius], soundcloud=[self.original])
        result = await harness.query()
        self.assertEqual(result["tracks"], [])
        self.assertEqual(harness.audius_calls, [])
        self.assertEqual(harness.soundcloud_calls, [])

    async def test_pending_progress_and_messages_are_preserved_without_internal_ids(self):
        progress = {"pending": True, "checked": 7, "total": 90, "retry_after": 1.8,
                    "message": "Источники продолжают поиск"}
        harness = self.harness(audius=[self.audius], soundcloud=[self.original],
                               progress=progress, message="Промежуточное сообщение")
        result = await harness.query()
        self.assertTrue(result["search_pending"])
        self.assertEqual(result["search_checked"], 7)
        self.assertEqual(result["search_total"], 90)
        self.assertEqual(result["search_retry_after"], 1.8)
        self.assertEqual(result["search_message"], progress["message"])
        self.assertEqual(result["soundcloud_message"], "")
        self.assertNotIn("ranked_ids", result)

    async def test_final_soundcloud_failure_message_is_not_discarded(self):
        harness = self.harness(audius=[self.audius], message="SoundCloud временно недоступен")
        result = await harness.query()
        self.assertEqual(result["soundcloud_message"], "SoundCloud временно недоступен")

    async def test_soundcloud_hit_never_waits_for_audius_timeout(self):
        harness = self.harness(audius_error=asyncio.TimeoutError(), soundcloud=[self.original])
        result = await harness.query()
        self.assertEqual(result["tracks"][0]["id"], "soundcloud-original")
        self.assertEqual(harness.audius_calls, [])
        self.assertEqual(len(harness.soundcloud_calls), 1)

    async def test_complete_empty_soundcloud_uses_audius_after_primary(self):
        harness = self.harness(audius=[self.audius])
        result = await harness.query()
        self.assertEqual(harness.provider_order, ["soundcloud", "audius"])
        self.assertEqual([row["id"] for row in result["tracks"]], ["audius-other"])

    async def test_pending_empty_soundcloud_defers_audius_and_cached_fallback(self):
        harness = self.harness(audius=[self.audius], cached=[self.audius],
                               progress={"pending": True, "retry_after": 2})
        result = await harness.query()
        self.assertTrue(result["search_pending"])
        self.assertEqual(harness.provider_order, ["soundcloud"])
        self.assertEqual(result["tracks"], [])

    async def test_unconfigured_soundcloud_uses_audius(self):
        harness = self.harness(audius=[self.audius], soundcloud_configured=False)
        result = await harness.query()
        self.assertEqual(harness.provider_order, ["audius"])
        self.assertEqual([row["id"] for row in result["tracks"]], ["audius-other"])

    async def test_soundcloud_failure_uses_audius_and_preserves_message(self):
        harness = self.harness(audius=[self.audius], message="SoundCloud временно недоступен")
        result = await harness.query()
        self.assertEqual(harness.provider_order, ["soundcloud", "audius"])
        self.assertEqual(result["tracks"][0]["id"], "audius-other")
        self.assertEqual(result["soundcloud_message"], "SoundCloud временно недоступен")

    async def test_audius_timeout_after_empty_primary_preserves_error(self):
        harness = self.harness(audius_error=asyncio.TimeoutError())
        result = await harness.query()
        self.assertEqual(harness.provider_order, ["soundcloud", "audius"])
        self.assertTrue(result["audius_message"])

    async def test_empty_query_does_not_discover_and_invalid_provider_still_fails(self):
        harness = self.harness(audius=[self.audius], soundcloud=[self.original])
        await harness.query(text="")
        self.assertEqual(harness.audius_calls, [])
        self.assertEqual(harness.soundcloud_calls, [])
        with self.assertRaises(ValueError):
            await harness.query(provider="unknown")


class RecommendationHarness:
    """Execute the supplied recommendation function against real SQLite rows."""
    def __init__(self, source, *, soundcloud=None, audius=None, cached=None,
                 soundcloud_configured=True, authenticated=True, hidden=None,
                 ineligible=None, favorite_ids=None):
        self.db = sqlite3.connect(":memory:")
        self.db.row_factory = sqlite3.Row
        self.db.executescript("""
            CREATE TABLE tracks(id TEXT PRIMARY KEY,title TEXT,artist TEXT,album TEXT,rights TEXT,duration REAL);
            CREATE TABLE likes(user_id TEXT,track_id TEXT);
            CREATE TABLE playlists(id TEXT,user_id TEXT);
            CREATE TABLE playlist_tracks(playlist_id TEXT,track_id TEXT);
            CREATE TABLE listening_sessions(user_id TEXT,track_id TEXT,listened REAL,skipped INTEGER,updated REAL);
            CREATE TABLE soundcloud_discovery(user_id TEXT,track_ids TEXT);
        """)
        self.provider_order = []
        self.audius_calls = []
        self.soundcloud_calls = []
        self.background_calls = []
        self.soundcloud = soundcloud or []
        self.audius = audius or []
        self.ineligible = set(ineligible or [])
        self.hidden = set(hidden or [])

        def store(_db, rows):
            for row in rows:
                self.db.execute("INSERT OR REPLACE INTO tracks VALUES(?,?,?,?,?,?)",
                    tuple(row[k] for k in ("id", "title", "artist", "album", "rights", "duration")))
            self.db.commit()

        def audius_search(query, limit):
            self.provider_order.append("audius")
            self.audius_calls.append((query, limit))
            return self.audius

        async def sc_search(account, seeds, **kwargs):
            self.provider_order.append("soundcloud")
            self.soundcloud_calls.append((seeds, kwargs))
            store(None, self.soundcloud)
            return {row["id"] for row in self.soundcloud}, ""

        async def threadpool(func, *args):
            return func(*args)

        def eligible(row, settings, favorites, heard):
            if row["id"] in self.ineligible:
                return False
            if settings["character"] == "favorites":
                return row["id"] in favorites
            return True

        self.modules = {
            "wave_preferences": SimpleNamespace(
                preferences=lambda settings: settings, eligible=eligible,
                boost=lambda *_: 0, seeds=lambda seeds, settings: seeds),
            "recommendation_signals": SimpleNamespace(event_signal=lambda *_: 0,
                                                      replay_cooldown=lambda *_: 0),
        }
        namespace = {
            "Request": object,
            "asyncio": SimpleNamespace(wait_for=asyncio.wait_for, to_thread=threadpool,
                                       TimeoutError=asyncio.TimeoutError),
            "time": time, "hashlib": hashlib, "json": json, "re": re,
            "core": SimpleNamespace(db=lambda: self.db),
            "session": lambda *_: {"user_id": "test-account"} if authenticated else None,
            "audius_provider": SimpleNamespace(configured=lambda: True, search_tracks=audius_search,
                                               AudiusUnavailable=RuntimeError),
            "audius_bridge": SimpleNamespace(store_tracks=store),
            "sc": SimpleNamespace(configured=lambda: soundcloud_configured),
            "discover_soundcloud": sc_search, "run_in_threadpool": threadpool,
            "schedule_audius_wave": lambda: self.background_calls.append("audius"),
            "schedule_discovery": lambda *_: self.background_calls.append("soundcloud"),
            "sync_preferences": lambda *_: (self.hidden, set()),
            "normalize_artist": lambda value: value.casefold(),
            "public": dict, "fail": lambda *_: (_ for _ in ()).throw(ValueError()),
            "PRELOAD_LOCK": threading.Lock(), "PRELOAD_PLANS": {},
        }
        tree = ast.parse(source)
        functions = [node for node in tree.body if isinstance(node, ast.AsyncFunctionDef)
                     and node.name == "recommendations"]
        for node in functions:
            node.decorator_list = []
        exec(compile(ast.Module(body=functions, type_ignores=[]), "<isolated recommendation route>", "exec"), namespace)
        self.route = namespace["recommendations"]
        store(None, cached or [])
        self.db.executemany("INSERT INTO likes VALUES('test-account',?)",
                            [(ident,) for ident in favorite_ids or []])
        self.db.commit()

    async def query(self, *, wave=True, exclude="", character="balanced", mix=""):
        request = SimpleNamespace(url=SimpleNamespace(path="/api/wave" if wave else "/api/recommendations"))
        with patch.dict(sys.modules, self.modules):
            return await self.route(request, exclude=exclude, character=character, mix=mix)

    def close(self):
        self.db.close()


class RecommendationPolicyTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.harnesses = []

    def tearDown(self):
        for harness in self.harnesses:
            harness.close()

    def rows(self, source, count, *, artist=None):
        return [track(f"{source}-{i}", f"Song {i}", artist or f"Artist {i}", source)
                for i in range(count)]

    def harness(self, *, original=False, **kwargs):
        harness = RecommendationHarness(FIXTURE if original else installer.patch(FIXTURE), **kwargs)
        self.harnesses.append(harness)
        return harness

    async def test_original_wave_queries_audius_before_soundcloud_and_can_skip_it(self):
        harness = self.harness(original=True, audius=self.rows("audius", 25),
                               soundcloud=self.rows("soundcloud", 20))
        await harness.query()
        self.assertEqual(harness.provider_order[0], "audius")
        self.assertEqual(harness.soundcloud_calls, [])

    async def test_enough_soundcloud_wave_never_queries_or_warms_audius(self):
        harness = self.harness(soundcloud=self.rows("soundcloud", 20),
                               audius=self.rows("audius", 25))
        result = await harness.query()
        self.assertEqual(harness.provider_order, ["soundcloud"])
        self.assertEqual(harness.background_calls, [])
        self.assertEqual(len(result["tracks"]), 20)
        self.assertTrue(all(json.loads(row["rights"])["source"] == "soundcloud"
                            for row in result["tracks"]))

    async def test_daily_recommendations_count_sixty_soundcloud_before_fallback(self):
        for count, expects_fallback in ((60, False), (20, True)):
            with self.subTest(count=count):
                harness = self.harness(soundcloud=self.rows("soundcloud", count),
                                       audius=self.rows("audius", 80))
                result = await harness.query(wave=False)
                self.assertEqual(harness.provider_order[0], "soundcloud")
                self.assertEqual(bool(harness.audius_calls), expects_fallback)
                self.assertEqual(len(result["tracks"]), 60)

    async def test_shortage_uses_audius_after_primary_and_keeps_sc_records_first(self):
        harness = self.harness(soundcloud=self.rows("soundcloud", 7),
                               audius=self.rows("audius", 25))
        result = await harness.query()
        self.assertEqual(harness.provider_order[0], "soundcloud")
        self.assertTrue(harness.audius_calls)
        self.assertLessEqual(len(harness.audius_calls), 2)
        self.assertEqual([json.loads(row["rights"])["source"] for row in result["tracks"][:7]],
                         ["soundcloud"] * 7)

    async def test_artist_diversity_cannot_promote_cached_audius_while_sc_remains(self):
        harness = self.harness(soundcloud=self.rows("soundcloud", 20, artist="One SC Artist"),
                               cached=self.rows("audius", 25))
        result = await harness.query()
        self.assertEqual(harness.provider_order, ["soundcloud"])
        self.assertEqual([json.loads(row["rights"])["source"] for row in result["tracks"]],
                         ["soundcloud"] * 20)

    async def test_excluded_hidden_and_ineligible_sc_do_not_hide_real_shortage(self):
        sc_rows = self.rows("soundcloud", 25)
        harness = self.harness(soundcloud=sc_rows, audius=self.rows("audius", 25),
                               hidden={"soundcloud-0", "soundcloud-1", "soundcloud-2"},
                               ineligible={"soundcloud-3", "soundcloud-4", "soundcloud-5"})
        result = await harness.query(exclude="soundcloud-6,soundcloud-7,soundcloud-8")
        self.assertTrue(harness.audius_calls)
        selected = {row["id"] for row in result["tracks"]}
        self.assertFalse(selected & {f"soundcloud-{i}" for i in range(9)})
        self.assertEqual(len(result["tracks"]), 20)

    async def test_unconfigured_sc_uses_fallback_and_favorites_never_discover(self):
        harness = self.harness(soundcloud_configured=False, audius=self.rows("audius", 25))
        await harness.query()
        self.assertEqual(harness.soundcloud_calls, [])
        self.assertTrue(harness.audius_calls)
        favorite = self.rows("audius", 1)[0]
        favorites = self.harness(cached=[favorite], favorite_ids=[favorite["id"]])
        result = await favorites.query(character="favorites")
        self.assertEqual(favorites.provider_order, [])
        self.assertEqual(favorites.background_calls, [])
        self.assertEqual([row["id"] for row in result["tracks"]], [favorite["id"]])


class DiscoverySchedulerTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.background = {}
        self.tasks = []
        self.provider_calls = []
        self.release = asyncio.Event()

        async def discover(account, seeds, *, advance=False, exclude_ids=None):
            self.provider_calls.append((account, seeds, advance, exclude_ids))
            await self.release.wait()
            return set(), ""

        namespace = {"asyncio": asyncio, "SC_BACKGROUND": self.background,
                     "discover_soundcloud": discover}
        tree = ast.parse(installer.patch(FIXTURE))
        node = next(node for node in tree.body if isinstance(node, ast.FunctionDef)
                    and node.name == "schedule_discovery")
        exec(compile(ast.Module(body=[node], type_ignores=[]), "<isolated discovery scheduler>", "exec"), namespace)
        self.schedule = namespace["schedule_discovery"]

    async def asyncTearDown(self):
        self.release.set()
        pending = list(set(self.tasks + list(self.background.values())))
        for task in pending:
            if not task.done():
                task.cancel()
        if pending:
            await asyncio.gather(*pending, return_exceptions=True)

    async def test_repeated_account_reuses_task_and_calls_provider_once(self):
        first = self.schedule({"user_id": "account"}, ["original seed"], {"heard"})
        self.tasks.append(first)
        second = self.schedule({"user_id": "account"}, ["later seed"], set())
        self.assertIsNotNone(first)
        self.assertIs(second, first)
        await asyncio.sleep(0)
        self.assertEqual(self.provider_calls,
                         [({"user_id": "account"}, ["original seed"], True, {"heard"})])
        self.release.set()
        await first
        await asyncio.sleep(0)
        self.assertNotIn("account", self.background)

    async def test_completed_task_is_removed_and_later_call_creates_new_task(self):
        first = self.schedule({"user_id": "account"}, ["seed"], set())
        self.tasks.append(first)
        self.release.set()
        await first
        await asyncio.sleep(0)
        self.assertEqual(self.background, {})
        second = self.schedule({"user_id": "account"}, ["new seed"], set())
        self.tasks.append(second)
        self.assertIsNot(second, first)
        await second
        await asyncio.sleep(0)
        self.assertEqual(len(self.provider_calls), 2)
        self.assertEqual(self.background, {})

    async def test_global_cap_rejects_new_account_but_returns_existing_task(self):
        for i in range(16):
            task = asyncio.create_task(self.release.wait())
            self.tasks.append(task)
            self.background[f"account-{i}"] = task
        existing = self.schedule({"user_id": "account-0"}, ["seed"], set())
        rejected = self.schedule({"user_id": "new-account"}, ["seed"], set())
        self.assertIs(existing, self.background["account-0"])
        self.assertIsNone(rejected)
        self.assertEqual(len(self.background), 16)
        await asyncio.sleep(0)
        self.assertEqual(self.provider_calls, [])


class InstallerTests(unittest.TestCase):
    def test_v1_installation_upgrades_to_soundcloud_primary_idempotently(self):
        nodes = installer.functions(FIXTURE)
        original_route = ast.get_source_segment(FIXTURE, nodes["tracks"])
        previous = FIXTURE.replace(original_route, installer.PREVIOUS_ROUTE, 1)
        previous = previous.replace(installer.DISCOVERY_RETURN, installer.DISCOVERY_PATCHED, 1)
        updated = installer.patch(previous)
        self.assertNotEqual(updated, previous)
        self.assertIn(installer.ROUTE, updated)
        self.assertEqual(installer.patch(updated), updated)

    def test_patch_is_idempotent_and_preserves_unrelated_source(self):
        prefix = "# custom deployment prefix\nuntouched_setting = 'retained'\n\n"
        suffix = "\n# custom deployment suffix\nuntouched_footer = 42\n"
        updated = installer.patch(prefix + FIXTURE + suffix)
        self.assertTrue(updated.startswith(prefix))
        self.assertTrue(updated.endswith(suffix))
        self.assertEqual(installer.patch(updated), updated)
        ast.parse(updated)

    def test_unknown_search_route_fails_closed(self):
        changed = FIXTURE.replace("q=q.strip().casefold()[:200]", "q=q.strip().casefold()[:199]", 1)
        with self.assertRaises(ValueError):
            installer.patch(changed)

    def test_unknown_soundcloud_discovery_fails_closed(self):
        changed = FIXTURE.replace("async with (SC_SEARCH_LIMIT if search else SC_DISCOVERY_LOCK):",
                                  "async with SC_DISCOVERY_LOCK:", 1)
        with self.assertRaises(ValueError):
            installer.patch(changed)

    def test_unknown_recommendation_route_fails_closed(self):
        changed = FIXTURE.replace("if len(exclude)>16000", "if len(exclude)>16001", 1)
        with self.assertRaises(ValueError):
            installer.patch(changed)

    def test_unknown_discovery_scheduler_fails_closed(self):
        changed = FIXTURE.replace("len(SC_BACKGROUND)>=16", "len(SC_BACKGROUND)>=15", 1)
        self.assertNotEqual(changed, FIXTURE)
        with self.assertRaises(ValueError):
            installer.patch(changed)

    def test_install_backup_and_rollback(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            app = root / "app.py"
            app.write_text(FIXTURE)
            backup = installer.install(root)
            self.assertIsNotNone(backup)
            self.assertNotEqual(app.read_text(), FIXTURE)
            self.assertTrue((root / "nightwell_search_recall.py").is_file())
            self.assertIsNone(installer.install(root))
            installer.rollback(backup)
            self.assertEqual(app.read_text(), FIXTURE)
            self.assertFalse((root / "nightwell_search_recall.py").exists())

    def test_optional_full_version_module_is_backed_up_and_rolled_back(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "app.py").write_text(FIXTURE)
            original = Path(__file__).with_name("fixture_full_version.py.txt").read_bytes()
            full_version = root / "full_version_search.py"
            full_version.write_bytes(original)
            backup = installer.install(root)
            self.assertNotEqual(full_version.read_bytes(), original)
            self.assertIn("NIGHTWELL_SEARCH_RECALL_FULL_VERSION_V1", full_version.read_text())
            self.assertIsNone(installer.install(root))
            installer.rollback(backup)
            self.assertEqual(full_version.read_bytes(), original)
            self.assertEqual((root / "app.py").read_text(), FIXTURE)

    def test_unknown_optional_module_prevents_any_installation(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            app = root / "app.py"
            app.write_text(FIXTURE)
            (root / "full_version_search.py").write_text("unexpected = True\n")
            with self.assertRaises(ValueError):
                installer.install(root)
            self.assertEqual(app.read_text(), FIXTURE)
            self.assertFalse((root / "nightwell_search_recall.py").exists())
            self.assertFalse((root / "backups").exists())

    def test_install_preserves_bom_crlf_and_unrelated_bytes(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            app = root / "app.py"
            prefix = "# Прочие настройки сервера не изменяются\r\ncustom_prefix = 1\r\n\r\n"
            suffix = "\r\n# Другие маршруты сервера\r\ncustom_suffix = 2\r\n"
            original = b"\xef\xbb\xbf" + (prefix + FIXTURE.replace("\n", "\r\n") + suffix).encode()
            app.write_bytes(original)
            backup = installer.install(root)
            updated = app.read_bytes()
            self.assertTrue(updated.startswith(b"\xef\xbb\xbf" + prefix.encode()))
            self.assertTrue(updated.endswith(suffix.encode()))
            self.assertNotIn(b"\n", updated.replace(b"\r\n", b""))
            self.assertIsNone(installer.install(root))
            installer.rollback(backup)
            self.assertEqual(app.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
