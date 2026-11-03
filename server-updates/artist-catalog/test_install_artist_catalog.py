import importlib.util
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "artist_installer", Path(__file__).with_name("install_artist_catalog.py"))
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallerTests(unittest.TestCase):
    def test_known_server_is_patched_before_entrypoint(self):
        source = (
            "from fastapi import FastAPI\n"
            "app=FastAPI()\n"
            "def identity(request): return 'user'\n"
            "@app.get('/api/tracks')\n"
            "def tracks(): return {'tracks':[]}\n"
            "if __name__ == '__main__':\n"
            "    print('started')\n"
        )
        modified, changed = installer.patch_server(source)
        self.assertTrue(changed)
        self.assertLess(modified.index("# Nightwell artist directory"),
                        modified.index("if __name__"))
        repeated, changed_again = installer.patch_server(modified)
        self.assertFalse(changed_again)
        self.assertEqual(modified, repeated)

    def test_unknown_server_is_untouched(self):
        with self.assertRaises(RuntimeError):
            installer.patch_server("app = None\n")

    def test_installer_copies_and_keeps_backup(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            app = root / "app.py"
            original = (
                "app = object()\n"
                "def identity(request): return 'user'\n"
                "# /api/tracks\n"
            )
            app.write_text(original, encoding="utf-8")
            backup, changed = installer.install(root)
            self.assertTrue(changed)
            self.assertTrue((root / "artist_catalog.py").is_file())
            self.assertEqual((backup / "app.py").read_text(encoding="utf-8"), original)
            self.assertIn("# Nightwell artist directory", app.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
