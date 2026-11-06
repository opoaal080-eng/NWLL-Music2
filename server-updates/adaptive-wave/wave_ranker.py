"""Bounded, deterministic music ranking from observed, account-scoped feedback.

The engine is intentionally inspectable. It does not pretend that titles are
musical embeddings, or infer mood, tempo or language from the audio itself.
"""
from collections import Counter, defaultdict
from dataclasses import dataclass
import hashlib
import json
import math
import random
import re
import unicodedata

DAY = 86400.0
ARTIST_SPLIT = re.compile(r"\s*(?:,|;|\bfeat\.?\s+|\bft\.?\s+|\s+[&×]\s+|\s+и\s+)\s*", re.I)
CREDIT = re.compile(r"^\s*(.{2,90}?)\s+[-–—]\s+(.{2,250}?)\s*$")
DECORATION = re.compile(r"[\[(](?:[^\])]*(?:official|audio|video|lyrics|visuali[sz]er|remaster|sped\s*up|slowed|reverb|nightcore|remix|ремикс|ускоренн|замедленн|hq|hd|4k)[^\])]*)[\])]", re.I)
STYLES = {
    'pop': {'pop', 'поп', 'попса'}, 'rock': {'rock', 'рок'},
    'metal': {'metal', 'метал', 'металл'}, 'rap': {'rap', 'hiphop', 'hip-hop', 'хип-хоп', 'рэп'},
    'folk': {'folk', 'народная', 'народные', 'фолк'}, 'phonk': {'phonk', 'фонк'},
    'electronic': {'electronic', 'edm', 'электроника', 'электронная'},
    'house': {'house', 'хаус'}, 'techno': {'techno', 'техно'},
    'jazz': {'jazz', 'джаз'}, 'ambient': {'ambient', 'chill', 'lofi', 'эмбиент'},
    'classical': {'classical', 'классика', 'симфоническая'},
    'chanson': {'chanson', 'шансон'}, 'rnb': {'rnb', 'r&b', 'соул', 'soul'},
    'indie': {'indie', 'инди'}, 'dance': {'dance', 'танцевальная', 'disco', 'диско'},
}


def number(value, default=0.0):
    try:
        result = float(value)
        return result if math.isfinite(result) else default
    except (TypeError, ValueError):
        return default


def key(value):
    text = unicodedata.normalize('NFKD', str(value or '').casefold().replace('ё', 'е'))
    return ''.join(ch for ch in text if ch.isalnum())


def artists(value):
    return frozenset(key(name) for name in ARTIST_SPLIT.split(str(value or '')) if key(name))


def track_info(row):
    row = dict(row)
    rights = row.get('rights') or {}
    if isinstance(rights, str):
        try:
            rights = json.loads(rights)
        except (ValueError, TypeError):
            rights = {}
    if not isinstance(rights, dict):
        rights = {}
    merged = dict(row)
    for field in ('genre', 'tags', 'language', 'mood', 'performer', 'artist_credit', 'metadata_artist', 'canonical_artist', 'artist_name'):
        if not merged.get(field) and rights.get(field):
            merged[field] = rights[field]
    title = str(row.get('title') or '')
    explicit_artist = merged.get('performer') or merged.get('artist_credit') or merged.get('metadata_artist') or merged.get('canonical_artist') or merged.get('artist_name')
    artist = str(explicit_artist or row.get('artist') or '')
    credit = CREDIT.fullmatch(title)
    if credit and rights.get('source') in {'soundcloud', 'audius'}:
        if not explicit_artist:
            artist, title = credit.groups()
        elif key(credit.group(1)) == key(explicit_artist):
            title = credit.group(2)
    merged['title'], merged['artist'] = title, artist
    # Recording-level deduplication also catches cross-source reuploads/edits.
    recording = '|'.join(sorted(artists(artist))) + '|' + key(DECORATION.sub('', title))
    raw_tags = merged.get('tags') or []
    if not isinstance(raw_tags, (list, tuple, set)):
        raw_tags = re.split(r'[,;#\s]+', str(raw_tags))
    tokens = {str(tag).casefold() for tag in raw_tags}
    tokens.update(re.findall(r'[\w&-]+', str(merged.get('genre') or '').casefold()))
    genres = frozenset(style for style, values in STYLES.items() if values & tokens)
    return Item(str(row.get('id') or ''), merged, rights, artists(artist), recording, genres)


@dataclass
class Item:
    id: str
    row: dict
    rights: dict
    artists: frozenset
    recording: str
    genres: frozenset


@dataclass
class Profile:
    artist: Counter
    session_artist: Counter
    genres: Counter
    track: Counter
    heard: set
    recent: dict
    blocked: set
    positive: bool


def listening_signal(seconds, duration, skipped):
    seconds, duration = max(0, number(seconds)), max(0, number(duration))
    # Buffering failures and accidental taps are not a musical dislike.
    if seconds < 3:
        return 0.0
    complete = duration >= 20 and seconds >= min(duration * .72, max(20, duration - 12))
    if complete:
        return 2.4
    if skipped and seconds < min(30, duration * .35 if duration > 0 else 30):
        return -2.0
    if seconds >= 60:
        return 1.2
    if seconds >= 30:
        return .65
    return .08 if not skipped and seconds >= 10 else 0.0


def build_profile(items, likes, saved, events, preferred, now):
    by_id = {item.id: item for item in items}
    artist, session_artist, genres, track = Counter(), Counter(), Counter(), Counter()
    heard, recent, skips, skip_times = set(), {}, Counter(), {}
    for tid, strength in [(tid, 4.0) for tid in likes] + [(tid, .9) for tid in saved - likes]:
        item = by_id.get(tid)
        if item:
            track[item.recording] += strength
            for name in item.artists:
                artist[name] += strength / max(1, len(item.artists))
            for genre in item.genres:
                genres[genre] += strength
    positive = bool(likes or saved or preferred)
    for event in events:
        item = by_id.get(str(event.get('track_id') or ''))
        if not item:
            continue
        seconds = max(0, number(event.get('listened')))
        updated = number(event.get('updated'))
        age = max(0, now - updated)
        duration = number(item.row.get('duration'))
        signal = listening_signal(seconds, duration, bool(event.get('skipped')))
        decay = .5 ** (age / (21 * DAY))
        if seconds >= 10:
            heard.add(item.recording)
        if seconds >= 3:
            recent[item.recording] = max(recent.get(item.recording, 0), updated)
        if signal < 0 and age <= 7 * DAY:
            skips[item.recording] += 1
            skip_times[item.recording] = max(skip_times.get(item.recording, 0), updated)
        track[item.recording] += signal * decay
        if signal > 0.1:
            positive = True
        # A single disliked song has limited influence on the whole artist.
        contribution = signal * decay * (.28 if signal < 0 else 1)
        for name in item.artists:
            artist[name] += contribution / max(1, len(item.artists))
            if age <= 45 * 60:
                session_artist[name] += contribution * (.5 ** (age / (20 * 60)))
        for genre in item.genres:
            genres[genre] += contribution
    # Saturation prevents a large old library from permanently dominating.
    artist = Counter({name: 3.1 * math.tanh(value / 8) for name, value in artist.items()})
    for name in preferred:
        artist[key(name)] = max(artist[key(name)], 4.8)
    session_artist = Counter({name: 1.8 * math.tanh(value / 4) for name, value in session_artist.items()})
    genres = Counter({name: math.tanh(value / 8) for name, value in genres.items()})
    blocked = {recording for recording, count in skips.items()
               if count >= 2 and now - skip_times[recording] < 2 * DAY}
    # One quick skip excludes that recording for the current listening session.
    blocked.update(recording for recording, timestamp in skip_times.items() if now - timestamp < 30 * 60)
    return Profile(artist, session_artist, genres, track, heard, recent, blocked, positive)


def rank(items, profile, likes, saved, excluded, hidden_ids, hidden_artists, exposures,
         settings, eligible, mood_boost, peer_scores, nonce, owner, now, limit=20):
    by_id = {item.id: item for item in items}
    denied = set(excluded) | set(hidden_ids)
    denied_recordings = {by_id[tid].recording for tid in denied if tid in by_id}
    liked_recordings = {by_id[tid].recording for tid in likes if tid in by_id}
    saved_recordings = {by_id[tid].recording for tid in saved if tid in by_id}
    hidden_artists = {key(name) for name in hidden_artists}
    rng = random.Random(hashlib.sha256((owner + '|' + nonce).encode()).digest())
    heard_ids = {item.id for item in items if item.recording in profile.heard | saved_recordings}
    disallowed_discoveries = profile.heard | liked_recordings | saved_recordings
    familiar_recordings = liked_recordings | saved_recordings
    candidates, unique = [], {}
    for item in items:
        if not item.id or item.rights.get('status') != 'approved':
            continue
        if item.id in denied or item.recording in denied_recordings or item.artists & hidden_artists:
            continue
        if item.recording in profile.blocked:
            continue
        age = now - profile.recent.get(item.recording, 0)
        if item.recording in profile.recent and age < 10 * 60:
            continue
        if settings['character'] == 'discover' and item.recording in disallowed_discoveries:
            continue
        if not eligible(item.row, settings, likes, heard_ids):
            continue
        strength = sum(profile.artist[name] + profile.session_artist[name] for name in item.artists)
        strength /= max(1, math.sqrt(len(item.artists)))
        familiar = item.recording in familiar_recordings or profile.track[item.recording] > .5
        genre_match = sum(profile.genres[tag] for tag in item.genres) / max(1, len(item.genres))
        related = strength > .2 or genre_match > .25 or peer_scores.get(item.id, 0) > .15
        value = strength + 1.6 * math.tanh(profile.track[item.recording] / 4)
        value += 1.7 * genre_match + min(2.0, peer_scores.get(item.id, 0))
        # Mood is an explicit metadata hint, never a title-word similarity score.
        value += max(-1.0, min(2.0, number(mood_boost(item.row, settings)) / 24))
        if item.recording in profile.recent:
            value -= 3.6 if age < 2 * 3600 else 1.4 if age < DAY else .4 if age < 3 * DAY else 0
        offered = now - exposures.get(item.recording, 0)
        if offered < 15 * 60:
            value -= 8.0
        elif offered < 3600:
            value -= 1.8
        if profile.positive and not related and not familiar:
            value -= 1.5
        value += rng.random() * .85
        entry = (item, value, familiar, related)
        previous = unique.get(item.recording)
        if previous is None or value > previous[1]:
            unique[item.recording] = entry
    candidates = list(unique.values())
    result, counts, last = [], Counter(), []
    while candidates and len(result) < limit:
        # Every fourth slot explores an unheard recording, preferably nearby in taste.
        explore = len(result) % 4 == 3 and settings['character'] != 'favorites'
        fresh = [entry for entry in candidates if now - exposures.get(entry[0].recording, 0) >= 15 * 60]
        pool = fresh or candidates
        # Apply artist spacing before the exploration lane. Otherwise a narrow
        # 'nearby new tracks' lane could force the same favourite artist again.
        recent_artists = set().union(*last[-3:]) if last else set()
        spaced = [entry for entry in pool if not entry[0].artists & recent_artists] if last else pool
        if not spaced:
            spaced = [entry for entry in pool if not entry[0].artists & last[-1]] if last else pool
        pool = spaced or pool
        if explore:
            unseen = [entry for entry in pool if entry[0].recording not in disallowed_discoveries]
            nearby = [entry for entry in unseen if entry[3]]
            pool = nearby or unseen or pool
        def adjusted(entry):
            item, value, _, _ = entry
            return value - .9 * sum(counts[name] for name in item.artists)
        chosen = max(pool, key=adjusted)
        item = chosen[0]
        result.append(item)
        counts.update(item.artists)
        last.append(item.artists)
        candidates.remove(chosen)
    return result
