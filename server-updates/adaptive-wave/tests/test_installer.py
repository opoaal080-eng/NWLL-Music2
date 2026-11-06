from pathlib import Path
import tempfile
import unittest
from install_adaptive_wave import BEGIN, install, patch, rollback

SOURCE = '''import server as core
app = object()
def session(request, required=True): return {'user_id': 'x'}
def public(row): return row
def listening(request): pass
def recommendations(request): pass
# /api/wave /api/listening
if __name__ == '__main__':
    print('existing launch')
'''


class InstallerTests(unittest.TestCase):
    def test_patch_is_additive_and_idempotent(self):
        changed = patch(SOURCE)
        self.assertEqual(patch(changed),changed)
        self.assertIn("def session(request, required=True): return {'user_id': 'x'}",changed)
        self.assertLess(changed.index(BEGIN),changed.index("if __name__"))
        self.assertEqual(changed.count(BEGIN),1)

    def test_unknown_server_is_not_modified(self):
        with self.assertRaises(ValueError):
            patch('app = object()')

    def test_install_twice_and_rollback_preserve_original_files(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root/'app.py').write_text(SOURCE,encoding='utf-8')
            (root/'wave_preferences.py').write_text('# existing policy',encoding='utf-8')
            (root/'unrelated.db').write_bytes(b'unchanged account data')
            first = install(root)
            self.assertEqual(len(first['changed']),3)
            self.assertEqual(install(root)['changed'],[])
            rollback(first['backup'])
            self.assertEqual((root/'app.py').read_text(),SOURCE)
            self.assertFalse((root/'adaptive_wave.py').exists())
            self.assertEqual((root/'unrelated.db').read_bytes(),b'unchanged account data')

    def test_rollback_does_not_clobber_later_user_edits(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root/'app.py').write_text(SOURCE,encoding='utf-8')
            (root/'wave_preferences.py').write_text('# existing policy',encoding='utf-8')
            result = install(root)
            (root/'app.py').write_text('# later edits',encoding='utf-8')
            with self.assertRaises(ValueError):
                rollback(result['backup'])
            self.assertEqual((root/'app.py').read_text(),'# later edits')


if __name__ == '__main__':
    unittest.main()
