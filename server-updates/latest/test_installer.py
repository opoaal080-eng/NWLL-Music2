import importlib.util
import tempfile
import unittest
from pathlib import Path

spec=importlib.util.spec_from_file_location(
    "latest_installer",Path(__file__).with_name("installer.py"))
module=importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

FAKE_APP=(
  "from fastapi import FastAPI\napp=FastAPI()\n"
  "def identity(request): return 'account'\n"
  "@app.get('/api/tracks')\ndef tracks():return {}\n"
  "@app.get('/api/stream/{id}')\ndef stream(id):return {}\n"
  "if __name__ == '__main__':\n    print('start')\n"
)

class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.server=Path(self.temp.name)/"server"
        self.server.mkdir()
        (self.server/"app.py").write_text(FAKE_APP,encoding="utf-8")
        self.payload=Path(self.temp.name)/"pkg"
        self.payload.mkdir()
        for name in module.FILES:
            (self.payload/name).write_text("value = 1\n",encoding="utf-8")

    def test_dry_run_leaves_server_unchanged(self):
        result=module.check(self.server,self.payload)
        self.assertEqual(len(result["changes"]),4)
        self.assertEqual((self.server/"app.py").read_text(),FAKE_APP)
        self.assertFalse((self.server/"backups").exists())

    def test_install_is_idempotent_and_can_rollback(self):
        backup,changed=module.install(self.server,self.payload)
        self.assertTrue(backup.is_dir())
        installed=(self.server/"app.py").read_text(encoding="utf-8")
        self.assertIn(module.BANNER_ARTIST,installed)
        self.assertIn(module.BANNER_QUALITY,installed)
        self.assertLess(installed.index(module.BANNER_QUALITY),installed.index("if __name__"))
        again,result=module.install(self.server,self.payload)
        self.assertIsNone(again)
        self.assertTrue(all(x["state"]=="same" for x in result))
        module.rollback(backup)
        self.assertEqual((self.server/"app.py").read_text(encoding="utf-8"),FAKE_APP)
        for name in module.FILES:self.assertFalse((self.server/name).exists())

    def test_preserves_existing_catalog_hook(self):
        app=FAKE_APP.replace("if __name__",module.HOOKS[0][1]+"\nif __name__")
        result=module.patch(app)
        self.assertEqual(result.count(module.BANNER_ARTIST),1)
        self.assertEqual(result.count(module.BANNER_QUALITY),1)

    def test_real_nightwell_session_contract(self):
        # Older production app.py exposes session(), not identity().
        legacy = (
            "from fastapi import FastAPI\napp=FastAPI()\n"
            "def session(request,required=True):\n"
            "    row = lookup('SELECT sessions.user_id FROM sessions')\n"
            "    if required and not row: raise ValueError('login required')\n"
            "    return dict(row) if row else None\n"
            "@app.get('/api/tracks')\ndef tracks():return {}\n"
            "@app.api_route('/api/stream/{tid}',methods=['GET','HEAD'])\n"
            "def stream(tid):return {}\n"
        )
        updated = module.patch(legacy)
        self.assertIn(module.BANNER_SESSION, updated)
        self.assertIn("def identity(request):", updated)
        self.assertIn("session(request, False)", updated)
        self.assertLess(updated.index(module.BANNER_SESSION),
                        updated.index(module.BANNER_ARTIST))
        self.assertEqual(module.patch(updated), updated)

    def test_ambiguous_auth_is_not_overwritten(self):
        unknown = (
            "app=1\ndef session(request):return {'user_id':'admin'}\n"
            "# /api/tracks and /api/stream\n"
        )
        with self.assertRaisesRegex(ValueError, "совместимая авторизация"):
            module.patch(unknown)

    def test_conflict_refused(self):
        (self.server/"app.py").write_text(FAKE_APP+"\n# /api/audio-quality/stream\n",encoding="utf-8")
        with self.assertRaises(ValueError):module.install(self.server,self.payload)
        self.assertFalse((self.server/"backups").exists())

    def test_rollback_refuses_modified_files(self):
        backup,_=module.install(self.server,self.payload)
        (self.server/"audio_quality.py").write_text("edited",encoding="utf-8")
        with self.assertRaisesRegex(ValueError,"изменился"):module.rollback(backup)

    def test_unknown_app_refused(self):
        (self.server/"app.py").write_text("app=12",encoding="utf-8")
        with self.assertRaisesRegex(ValueError,"не распознан"):module.check(self.server,self.payload)

if __name__=="__main__":unittest.main()
