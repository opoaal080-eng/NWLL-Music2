"""Installer tests only use temporary fixtures, never a production server."""
import ast
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import install_account_access as installer

APP = '''from types import SimpleNamespace
app = SimpleNamespace(state=SimpleNamespace())
premium_service = object()
def identity(request):
    return "fixture"
def premium_csrf(request):
    return True

if __name__ == "__main__":
    print("fixture server")
'''
ADAPTER = '''ADAPTER_CONFIGURED = True
def configure(**kwargs):
    return object()
'''


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.target = self.root / "server"
        self.target.mkdir()
        self.source = self.root / "package"
        self.source.mkdir()
        (self.target / "app.py").write_text(APP, encoding="utf-8")
        self.adapter = self.root / "configured_adapter.py"
        self.adapter.write_text(ADAPTER, encoding="utf-8")
        for index, name in enumerate(installer.REQUIRED_MODULES):
            body = f"VALUE = {index}\n" if name.endswith(".py") else "<!doctype html><title>Family</title>"
            (self.source / name).write_text(body, encoding="utf-8")
        self.env = b"DO_NOT_TOUCH=private-placeholder\r\n"
        self.db = b"existing production fixture database\x00\x01"
        (self.target / ".env").write_bytes(self.env)
        (self.target / "music.sqlite3").write_bytes(self.db)

    def install(self, **kwargs):
        return installer.install(self.target, self.adapter, source_dir=self.source, **kwargs)

    def assert_untouched(self):
        self.assertEqual((self.target / ".env").read_bytes(), self.env)
        self.assertEqual((self.target / "music.sqlite3").read_bytes(), self.db)
        self.assertFalse((self.target / "account_access.sqlite3").exists())

    def test_check_is_read_only(self):
        before = sorted(p.name for p in self.target.iterdir())
        result = self.install(check=True)
        self.assertTrue(result["compatible"])
        self.assertEqual(result["status"], "changes_required")
        self.assertEqual(sorted(p.name for p in self.target.iterdir()), before)
        self.assertEqual((self.target / "app.py").read_text(), APP)
        self.assert_untouched()

    def test_install_and_idempotent_repeat(self):
        result = self.install()
        self.assertEqual(result["status"], "installed")
        installed = (self.target / "app.py").read_text()
        self.assertEqual(installed.count(installer.BEGIN), 1)
        self.assertLess(installed.index(installer.BEGIN), installed.index('if __name__'))
        ast.parse(installed)
        second = self.install()
        self.assertEqual(second["status"], "up_to_date")
        self.assertIsNone(second["backup"])
        self.assertFalse(second["restart_required"])
        self.assertEqual(len(list((self.target / "backups").iterdir())), 1)
        self.assertEqual((self.target / "app.py").read_text(), installed)
        self.assert_untouched()

    def test_updates_module_without_duplicating_hook(self):
        self.install()
        (self.source / "family_access.py").write_text("VALUE = 'updated'\n", encoding="utf-8")
        result = self.install()
        self.assertEqual(result["changed_files"], ["family_access.py"])
        self.assertEqual((self.target / "app.py").read_text().count(installer.BEGIN), 1)
        self.assertEqual((self.target / "family_access.py").read_text(), "VALUE = 'updated'\n")

    def test_restore_previous_module_and_remove_new_files(self):
        previous_module = b"OLD = True\r\n"
        (self.target / "family_access.py").write_bytes(previous_module)
        result = self.install()
        manifest = json.loads((Path(result["backup"]) / "manifest.json").read_text())
        app_entry = manifest["files"]["app.py"]
        self.assertEqual(app_entry["before_sha256"], hashlib.sha256(APP.encode()).hexdigest())
        installer.restore(self.target, result["backup"])
        self.assertEqual((self.target / "app.py").read_bytes(), APP.encode())
        self.assertEqual((self.target / "family_access.py").read_bytes(), previous_module)
        self.assertFalse((self.target / "account_access.py").exists())
        self.assertFalse((self.target / installer.ADAPTER_NAME).exists())
        self.assert_untouched()

    def test_failure_rolls_back_all_replacements(self):
        previous_module = b"ORIGINAL = True\n"
        (self.target / "access_database.py").write_bytes(previous_module)
        original_write = installer._atomic_write
        calls = []

        def write(path, data):
            calls.append(path.name)
            if len(calls) == 3:
                raise OSError("simulated replacement failure")
            return original_write(path, data)

        with mock.patch.object(installer, "_atomic_write", side_effect=write):
            with self.assertRaises(installer.InstallError):
                self.install()
        self.assertEqual((self.target / "app.py").read_bytes(), APP.encode())
        self.assertEqual((self.target / "access_database.py").read_bytes(), previous_module)
        self.assertFalse((self.target / "family_access.py").exists())
        self.assertFalse((self.target / installer.ADAPTER_NAME).exists())
        self.assert_untouched()

    def test_backup_corruption_is_detected_before_restore_writes(self):
        result = self.install()
        backup = Path(result["backup"])
        (backup / "app.py").write_text("corrupt", encoding="utf-8")
        installed = (self.target / "app.py").read_bytes()
        with self.assertRaises(installer.InstallError):
            installer.restore(self.target, backup)
        self.assertEqual((self.target / "app.py").read_bytes(), installed)

    def test_restore_rejects_other_target_and_path_traversal(self):
        result = self.install()
        backup = Path(result["backup"])
        other = self.root / "other"
        other.mkdir()
        with self.assertRaises(installer.InstallError):
            installer.restore(other, backup)
        manifest = json.loads((backup / "manifest.json").read_text())
        manifest["files"]["../.env"] = {"existed": False}
        (backup / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        with self.assertRaises(installer.InstallError):
            installer.restore(self.target, backup)

    def test_adapter_must_be_explicitly_configured(self):
        for flag in ["False", "1", "bool(1)", "True\nADAPTER_CONFIGURED = False"]:
            with self.subTest(flag=flag):
                self.adapter.write_text(ADAPTER.replace("True", flag, 1), encoding="utf-8")
                with self.assertRaises(installer.InstallError):
                    self.install(check=True)
        self.assertFalse((self.target / "backups").exists())

    def test_adapter_signature_and_async_configure_rejected(self):
        for source in [
            "ADAPTER_CONFIGURED=True\ndef configure(app):\n    pass\n",
            "ADAPTER_CONFIGURED=True\nasync def configure(**kwargs):\n    pass\n",
        ]:
            with self.subTest(source=source):
                self.adapter.write_text(source, encoding="utf-8")
                with self.assertRaises(installer.InstallError):
                    self.install(check=True)

    def test_production_app_and_adapter_are_never_imported(self):
        (self.target / "app.py").write_text("raise RuntimeError('do not import')\n" + APP, encoding="utf-8")
        self.adapter.write_text("raise RuntimeError('do not import')\n" + ADAPTER, encoding="utf-8")
        self.install(check=True)
        self.assertFalse((self.target / "backups").exists())

    def test_missing_host_symbols_and_route_conflicts_rejected(self):
        for source in [APP.replace("premium_service = object()", ""), APP + '\n@app.get("/api/devices")\ndef collision():\n    pass\n']:
            with self.subTest(source=source):
                (self.target / "app.py").write_text(source, encoding="utf-8")
                with self.assertRaises(installer.InstallError):
                    self.install(check=True)
        self.assertFalse((self.target / "backups").exists())

    def test_old_device_registry_and_broken_marker_rejected(self):
        for tail in ["\n" + installer.OLD_MARKER, "\n" + installer.BEGIN]:
            with self.subTest(tail=tail):
                (self.target / "app.py").write_text(APP + tail, encoding="utf-8")
                with self.assertRaises(installer.InstallError):
                    self.install(check=True)

    def test_payload_completeness_and_python_syntax(self):
        html = self.source / "family_page.html"
        html.unlink()
        with self.assertRaises(installer.InstallError):
            self.install(check=True)
        html.write_text("<html></html>")
        (self.source / "device_access.py").write_text("def broken(")
        with self.assertRaises(installer.InstallError):
            self.install(check=True)
        self.assertFalse((self.target / "backups").exists())

    def test_utf8_bom_and_crlf_preserved(self):
        original = b"\xef\xbb\xbf" + APP.replace("\n", "\r\n").encode()
        (self.target / "app.py").write_bytes(original)
        result = self.install()
        installed = (self.target / "app.py").read_bytes()
        self.assertTrue(installed.startswith(b"\xef\xbb\xbf"))
        self.assertNotIn(b"\n", installed.replace(b"\r\n", b""))
        self.assertEqual(self.install()["status"], "up_to_date")
        installer.restore(self.target, result["backup"])
        self.assertEqual((self.target / "app.py").read_bytes(), original)

    def test_reversed_or_missing_main_guard(self):
        for source in [APP.replace('if __name__ == "__main__":', 'if "__main__" == __name__:'), APP[:APP.index('if __name__')]]:
            result = installer.patch(source)
            ast.parse(result)
            self.assertEqual(installer.patch(result), result)
        with self.assertRaises(installer.InstallError):
            installer.patch(APP + '\nif __name__ == "__main__":\n    pass\n')

    def test_unguarded_server_start_is_rejected(self):
        prefix = APP[:APP.index('if __name__')]
        for startup in [
            "import uvicorn\nuvicorn.run(app)\n",
            "import uvicorn as uv\nuv.run(app)\n",
            "from uvicorn import run as serve\nserve(app)\n",
            "import asyncio\nasyncio.run(start_server())\n",
        ]:
            with self.subTest(startup=startup):
                with self.assertRaises(installer.InstallError):
                    installer.patch(prefix + startup)

    def test_semantically_invalid_python_rejected(self):
        (self.source / "device_access.py").write_text("return 1\n")
        with self.assertRaises(installer.InstallError):
            self.install(check=True)
        self.assertFalse((self.target / "backups").exists())

    @unittest.skipUnless(hasattr(os, "chmod") and os.name != "nt", "POSIX mode check")
    def test_existing_app_file_mode_preserved(self):
        os.chmod(self.target / "app.py", 0o640)
        self.install()
        self.assertEqual((self.target / "app.py").stat().st_mode & 0o777, 0o640)


if __name__ == "__main__":
    unittest.main()
