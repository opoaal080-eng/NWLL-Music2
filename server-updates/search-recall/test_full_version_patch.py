from pathlib import Path
import unittest

from full_version_patch import patch


FIXTURE = Path(__file__).with_name('fixture_full_version.py.txt').read_text()


def load(patched=True):
    scope = {}
    exec(compile(patch(FIXTURE) if patched else FIXTURE, '<full-version-fixture>', 'exec'), scope)
    return scope


def track(title='Грустный дэнс', artist='Artik & Anna Asti', duration=189, **kwargs):
    return dict(title=title, artist=artist, duration=duration,
                access='playable', streamable=True, **kwargs)


class FullVersionPatchTests(unittest.TestCase):
    def test_baseline_reproduces_cross_query_cancellation(self):
        module = load(False)
        module['search'](['first'], wait=0, owner='account')
        first = next(iter(module['_RECORDS'].values()))
        module['search'](['second'], wait=0, owner='account')
        self.assertTrue(first['cancel'].is_set())

    def test_parallel_transfer_and_spelling_queries_do_not_cancel_each_other(self):
        module = load()
        for query in ['грустный дэнс', 'grustnyy dens', 'Другая песня']:
            module['search']([query], wait=0, owner='same-account')
        self.assertEqual(len(module['_RECORDS']), 3)
        self.assertEqual(len(module['_OWNERS']), 3)
        self.assertTrue(all(not record['cancel'].is_set()
                            for record in module['_RECORDS'].values()))
        module['search'](['грустный дэнс'], wait=0, owner='same-account')
        self.assertEqual(len(module['_OWNERS']), 3)

    def test_owner_bound_removes_only_evicted_registration(self):
        module = load()
        for n in range(257):
            module['search'](['same-query'], wait=0, owner='owner-' + str(n))
        record = next(iter(module['_RECORDS'].values()))
        self.assertEqual(len(module['_OWNERS']), 256)
        self.assertEqual(len(record['owners']), 256)
        self.assertNotIn('owner-0', record['owners'])
        self.assertFalse(record['cancel'].is_set())

    def test_global_query_limit_still_cancels_evicted_job(self):
        module = load()
        module['search'](['first'], wait=0, owner='account')
        first = next(iter(module['_RECORDS'].values()))
        for n in range(32):
            module['search'](['query-' + str(n)], wait=0, owner='account')
        self.assertTrue(first['cancel'].is_set())
        self.assertEqual(len(module['_RECORDS']), 32)
        self.assertEqual(len(module['_OWNERS']), 32)
        self.assertTrue(all(registration[1] in module['_RECORDS']
                            for registration in module['_OWNERS']))

    def test_featured_title_matches_same_recording(self):
        module = load()
        for suffix in ['(при уч. Артем Качер)', '(при участии Артём Качер)',
                       '[при участ. Артем Качер]', 'feat. Артем Качер']:
            reference = track(title='Грустный дэнс ' + suffix)
            candidate = track()
            with self.subTest(suffix=suffix):
                self.assertTrue(module['same_recording'](reference, candidate))
                self.assertEqual(module['song_key'](reference), module['song_key'](candidate))
        self.assertFalse(load(False)['same_recording'](
            track(title='Грустный дэнс (при уч. Артем Качер)'), track()))

    def test_credit_normalization_preserves_recording_guards(self):
        same = load()['same_recording']
        source = track(title='Грустный дэнс (при уч. Артем Качер)')
        for candidate in [track(title='Грустный дэнс (Remix)'),
                          track(title='Грустный дэнс (Live)'),
                          track(artist='INSTASAMKA'),
                          track(duration=30)]:
            self.assertFalse(same(source, candidate), candidate)
        featured_live = track(title='Грустный дэнс (при уч. Артем Качер) (Live)')
        self.assertFalse(same(featured_live, track()))
        self.assertTrue(same(featured_live, track(title='Грустный дэнс (Live)')))

    def test_patcher_is_idempotent_and_preserves_line_endings(self):
        for original in [FIXTURE, '\ufeff' + FIXTURE.replace('\n', '\r\n')]:
            result = patch(original)
            self.assertEqual(patch(result), result)
            self.assertEqual(result.startswith('\ufeff'), original.startswith('\ufeff'))
            self.assertEqual('\r\n' in result, '\r\n' in original)

    def test_unknown_worker_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Unsupported'):
            patch(FIXTURE.replace('while len(_OWNERS)>256:', 'while len(_OWNERS)>128:'))


if __name__ == '__main__':
    unittest.main()
