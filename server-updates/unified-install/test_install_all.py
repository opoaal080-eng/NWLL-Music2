import importlib.util
import tempfile
import unittest
from pathlib import Path

MODULE = Path(__file__).with_name("install_all.py")
spec = importlib.util.spec_from_file_location("nightwell_install_all", MODULE)
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)

SERVER = (
    "app = object()\n"
    "def identity(request): return 'test-user'\n"
    "@app.get('/api/tracks')\n"
    "def tracks(): return {'tracks': []}\n"
    "if __name__ == '__main__':\n"
    "    print('starting')\n"
)


class UnifiedInstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.target = Path(self.temp.name) / "my-server"
        self.target.mkdir()
        (self.target / "app.py").write_text(SERVER, encoding="utf-8")

    def test_patches_before_main_and_is_idempotent(self):
        first, hooks = installer.patch_app(SERVER)
        self.assertEqual(len(hooks), 2)
        self.assertLess(first.index(installer.ARTIST_MARKER), first.index("if __name__"))
        self.assertLess(first.index(installer.DAILY_MARKER), first.index("if __name__"))
        second, hooks = installer.patch_app(first)
        self.assertEqual(hooks, [])
        self.assertEqual(first, second)

    def test_unknown_layout_is_not_modified(self):
        (self.target / "app.py").write_text("app = 3\n", encoding="utf-8")
        with self.assertRaisesRegex(RuntimeError, "Неизвестная версия"):
            installer.apply(self.target)
        self.assertEqual((self.target / "app.py").read_text(encoding="utf-8"), "app = 3\n")

    def test_conflicting_route_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "дубль"):
            installer.patch_app(SERVER + "\n# /api/artists\n")

    def test_check_mode_has_no_side_effects(self):
        result = installer.plan(self.target)
        self.assertEqual(result["target"], str(self.target.resolve()))
        self.assertTrue(all(x["action"] == "add" or x["action"] == "update"
                            for x in result["files"]))
        self.assertEqual((self.target / "app.py").read_text(encoding="utf-8"), SERVER)
        self.assertFalse((self.target / "backups").exists())

    def test_install_and_rollback_and_preexisting_import(self):
        preexisting = self.target / "music_import.py"
        preexisting.write_text("OLD IMPORT DATA", encoding="utf-8")
        backup, actions = installer.apply(self.target)
        self.assertIsNotNone(backup)
        self.assertEqual(len(actions["hooks"]), 2)
        for expected in installer.SOURCES:
            self.assertTrue((self.target / expected).is_file(), expected)
        app = (self.target / "app.py").read_text(encoding="utf-8")
        self.assertIn(installer.ARTIST_MARKER, app)
        self.assertIn(installer.DAILY_MARKER, app)
        self.assertEqual((backup / "original" / "app.py").read_text(encoding="utf-8"),
                         SERVER)
        self.assertEqual((backup / "original" / "music_import.py").read_text(
                         encoding="utf-8"), "OLD IMPORT DATA")
        unchanged_backup, actions_again = installer.apply(self.target)
        self.assertIsNone(unchanged_backup)
        self.assertTrue(all(x["action"] == "unchanged"
                            for x in actions_again["files"]))
        installer.rollback(backup)
        self.assertEqual((self.target / "app.py").read_text(encoding="utf-8"), SERVER)
        self.assertEqual(preexisting.read_text(encoding="utf-8"), "OLD IMPORT DATA")
        self.assertFalse((self.target / "artist_metadata.py").exists())

    def test_does_not_rollback_modified_file(self):
        backup, _ = installer.apply(self.target)
        file = self.target / "artist_metadata.py"
        file.write_text("new local user change", encoding="utf-8")
        with self.assertRaisesRegex(RuntimeError, "изменился"):
            installer.rollback(backup)
        self.assertEqual(file.read_text(encoding="utf-8"), "new local user change")


if __name__ == "__main__":
    unittest.main()
