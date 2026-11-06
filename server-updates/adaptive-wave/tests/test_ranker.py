import unittest
from collections import Counter
import legacy_preferences as settings
from wave_ranker import build_profile, listening_signal, rank, track_info

NOW = 1_800_000_000.0


def song(tid, artist='Artist A', title=None, **rights):
    return track_info({'id': tid, 'artist': artist, 'title': title or 'Track '+tid,
                      'album': '', 'duration': 200, 'rights': {'status': 'approved', **rights}})


def choose(items, likes=None, events=None, saved=None, preferred=None, exclude=None,
           hidden=None, hidden_artists=None, exposures=None, mode='balanced', language='any', nonce='mix'):
    likes, events, saved = set(likes or []), events or [], set(saved or [])
    profile = build_profile(items, likes, saved, events, preferred or [], NOW)
    return rank(items, profile, likes, saved, set(exclude or []), set(hidden or []), set(hidden_artists or []), exposures or {},
                {'character': mode, 'language': language, 'mood': 'any'}, settings.eligible, settings.boost,
                Counter(), nonce, 'alice', NOW, 20)


class RankingTests(unittest.TestCase):
    def test_completion_is_positive_even_when_next_button_was_used(self):
        self.assertGreater(listening_signal(190, 200, True), 0)
        self.assertLess(listening_signal(8, 200, True), 0)

    def test_buffering_failure_is_not_a_dislike(self):
        self.assertEqual(listening_signal(0, 200, True), 0)
        self.assertEqual(listening_signal(2, 200, True), 0)

    def test_duplicate_cross_source_recordings_are_merged(self):
        items = [song('one', 'Artist A', 'A song'),
                 song('two', 'Uploader', 'Artist A — A song (Official Audio)', source='soundcloud'),
                 song('other', 'Artist B')]
        result = choose(items)
        self.assertEqual(len(result), 2)
        self.assertEqual(len({item.recording for item in result}), 2)

    def test_exclude_applies_to_other_recordings_of_same_song(self):
        items = [song('one', title='My song'), song('two', title='My song [Official Audio]'), song('three')]
        self.assertEqual([item.id for item in choose(items, exclude=['one'])], ['three'])

    def test_two_skips_hide_recording_for_48_hours(self):
        items = [song('bad'), song('copy', title='Track bad (Slowed)'), song('good', 'Artist B')]
        events = [dict(track_id='bad', listened=8, skipped=True, updated=NOW-6000),
                  dict(track_id='copy', listened=10, skipped=True, updated=NOW-5000)]
        self.assertEqual([item.id for item in choose(items, events=events)], ['good'])
        for event in events:
            event['updated'] -= 2*86400
        self.assertTrue({'bad', 'copy'} & {item.id for item in choose(items, events=events)})

    def test_single_skip_affects_current_session_only(self):
        items = [song('bad'), song('good', 'Artist B')]
        recent = [dict(track_id='bad', listened=8, skipped=True, updated=NOW-60)]
        self.assertNotIn('bad', [item.id for item in choose(items, events=recent)])
        recent[0]['updated'] = NOW-3600
        self.assertIn('bad', [item.id for item in choose(items, events=recent)])

    def test_discovery_excludes_saved_and_liked_canonical_songs(self):
        items = [song('like'), song('save'), song('save-copy', title='Track save [Official Audio]'), song('new')]
        result = choose(items, likes=['like'], saved=['save'], mode='discover')
        self.assertEqual([item.id for item in result], ['new'])

    def test_language_applies_to_selected_artists_too(self):
        items = [song('english', 'Favourite', language='en'), song('russian', 'Other', language='ru')]
        self.assertEqual([item.id for item in choose(items, preferred=['Favourite'], language='ru')], ['russian'])

    def test_hidden_artists_are_filtered_even_in_favourites(self):
        items = [song('a', 'Hidden'), song('b', 'Allowed')]
        result = choose(items, likes=['a', 'b'], hidden_artists=['hidden'], mode='favorites')
        self.assertEqual([item.id for item in result], ['b'])

    def test_favourite_mode_never_injects_other_tracks(self):
        items = [song('like'), song('other')]
        self.assertEqual([item.id for item in choose(items, likes=['like'], mode='favorites')], ['like'])

    def test_multiple_artists_do_not_repeat_within_three_tracks(self):
        items = [song(f'{name}-{i}', name) for name in ['A', 'B', 'C', 'D'] for i in range(8)]
        result = choose(items, preferred=['A'])
        for i, item in enumerate(result):
            for previous in result[max(0,i-3):i]:
                self.assertFalse(item.artists & previous.artists)

    def test_new_batch_uses_unoffered_tracks_first(self):
        items = [song(f'a{i}', 'Favourite') for i in range(20)] + [song(f'b{i}', 'Other') for i in range(20)]
        exposures = {item.recording: NOW-20 for item in items[:20]}
        result = choose(items, likes=[item.id for item in items[:20]], exposures=exposures)
        self.assertTrue(all(item.id.startswith('b') for item in result))

    def test_seed_is_reproducible_but_different_mix_changes_order(self):
        items = [song(str(i), 'A'+str(i % 8)) for i in range(40)]
        a = [item.id for item in choose(items, nonce='one')]
        self.assertEqual(a, [item.id for item in choose(items, nonce='one')])
        self.assertNotEqual(a, [item.id for item in choose(items, nonce='two')])

    def test_song_words_do_not_create_taste_similarity(self):
        items = [song('liked', 'A', 'Любовь'), song('same', 'B', 'Любовь'), song('other', 'C', 'Параллель')]
        first = [item.id for item in choose(items, likes=['liked'])]
        items[1] = song('same', 'B', 'Совершенно другое название')
        self.assertEqual(first, [item.id for item in choose(items, likes=['liked'])])

    def test_old_history_has_bounded_artist_weight(self):
        items = [song('a', 'A')]
        events = [dict(track_id='a', listened=190, skipped=False, updated=NOW-86400-i) for i in range(1000)]
        profile = build_profile(items, set(), set(), events, [], NOW)
        self.assertLessEqual(profile.artist['a'], 3.1)

    def test_recent_listening_adds_session_context(self):
        items = [song('a', 'A'), song('b', 'B')]
        profile = build_profile(items, set(), set(), [dict(track_id='a', listened=190, skipped=False, updated=NOW-60)], [], NOW)
        self.assertGreater(profile.session_artist['a'], profile.session_artist['b'])

    def test_genre_metadata_finds_nearby_new_artists(self):
        items = [song('like', 'A', genre='rock'), song('near', 'C', genre='rock'), song('far', 'B', genre='pop')]
        result = [item.id for item in choose(items, likes=['like'])]
        self.assertLess(result.index('near'), result.index('far'))

    def test_explicit_performer_is_not_replaced_with_uploader_or_title_guess(self):
        item = song('metadata', 'Upload channel', 'Wrong artist — Song', source='soundcloud', canonical_artist='Real Artist')
        self.assertEqual(item.artists, frozenset({'realartist'}))

    def test_unapproved_tracks_never_enter_candidates(self):
        revoked = track_info({'id':'revoked','title':'Song','artist':'Favourite','rights':{'status':'revoked'}})
        self.assertEqual(choose([revoked], preferred=['Favourite']), [])

    def test_malformed_metadata_and_nonfinite_signal_are_safe(self):
        item = track_info({'id': 'x', 'title': 'x', 'artist': 'x', 'rights': '{broken', 'duration': 100})
        self.assertEqual(choose([item]), [])
        self.assertEqual(listening_signal(float('nan'), 200, True), 0)


if __name__ == '__main__':
    unittest.main()
