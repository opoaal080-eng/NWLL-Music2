"""Regression tests for the Nightwell device registry deployer."""
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import install_account_devices as deploy


SAMPLE_APP = """app = object()
premium_service = object()

def identity(request):
    return "member"

def premium_csrf(request):
    return True

if __name__ == "__main__":
    print("server started")
"""


class InstallerTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.app = self.root / "app.py"
        self.app.write_text(SAMPLE_APP, encoding="utf-8")
        self.module = self.root / "account_devices.py"

    def test_patch_is_idempotent_and_before_main(self):
        result = deploy.patch(SAMPLE_APP)
        self.assertEqual(result.count(deploy.MARKER), 1)
        self.assertLess(result.index(deploy.MARKER), result.index('if __name__'))
        self.assertIn("from pathlib import Path", result)
        self.assertEqual(deploy.patch(result), result)

    def test_patch_accepts_annotated_globals(self):
        code = SAMPLE_APP.replace("app = object()", "app: object = object()").replace(
            "premium_service = object()", "premium_service: object = object()")
        self.assertIn(deploy.MARKER, deploy.patch(code))

    def test_incompatible_host_is_not_modified(self):
        self.app.write_text("app = object()\n", encoding="utf-8")
        with self.assertRaises(RuntimeError):
            deploy.install(self.root)
        self.assertFalse(self.module.exists())
        self.assertEqual(self.app.read_text(encoding="utf-8"), "app = object()\n")

    def test_installer_updates_module_on_repeat_deployment(self):
        self.assertIn("требуется установка", deploy.install(self.root, check=True))
        deploy.install(self.root)
        current_app = self.app.read_bytes()
        source_module = Path(deploy.__file__).with_name("account_devices.py").read_bytes()
        self.assertEqual(self.module.read_bytes(), source_module)
        self.assertIn("актуален", deploy.install(self.root, check=True))

        self.module.write_text("# stale module\n", encoding="utf-8")
        self.assertIn("обновление модуля", deploy.install(self.root, check=True))
        deploy.install(self.root)
        self.assertEqual(self.module.read_bytes(), source_module)
        self.assertEqual(self.app.read_bytes(), current_app)
        self.assertGreaterEqual(len(list((self.root / "backups").glob("account-devices-*"))), 2)

    def test_restores_both_files_after_partial_install_failure(self):
        self.module.write_text("# prior module\n", encoding="utf-8")
        original_replace = deploy.os.replace
        count = 0

        def fail_on_app_replacement(src, dst):
            nonlocal count
            count += 1
            if count == 2:
                raise OSError("simulated interrupted deployment")
            return original_replace(src, dst)

        with mock.patch.object(deploy.os, "replace", side_effect=fail_on_app_replacement):
            with self.assertRaisesRegex(OSError, "simulated"):
                deploy.install(self.root)
        self.assertEqual(self.app.read_text(encoding="utf-8"), SAMPLE_APP)
        self.assertEqual(self.module.read_text(encoding="utf-8"), "# prior module\n")
        self.assertFalse((self.root / "app.py.account-devices.tmp").exists())
        self.assertFalse((self.root / "account_devices.py.account-devices.tmp").exists())


if __name__ == "__main__":
    unittest.main()
