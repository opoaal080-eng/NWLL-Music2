"""Resolve performer credits in Nightwell Music without mistaking an upload account for an artist.

No network calls, no metadata scraping and no changes to playback identifiers.
Track objects returned by the existing server may contain "artist" = uploader.
This module only trusts explicit performer/artist_credit fields, or an
unambiguous "Performer — Song" title on remote records.
"""
import re
from urllib.parse import urlsplit

UNKNOWN = "Исполнитель не указан"
TITLE_CREDIT = re.compile(r"^\s*(.{2,90}?)\s+[-–—]\s+(.{2,250}?)\s*$")
VERSIONS = {
    "remix", "live", "slowed", "spedup", "sped up", "nightcore",
    "instrumental", "radio edit", "official", "lyrics", "ремикс",
    "лайв", "кавер", "ускоренная", "замедленная", "инструментал",
}


def remote_source(track):
    if track.get("is_remote") is True:
        return True
    source = track.get("source")
    if isinstance(source, str) and "soundcloud" in source.casefold():
        return True
    url = track.get("source_url")
    if not isinstance(url, str):
        return False
    try:
        host = (urlsplit(url).hostname or "").lower()
        return host == "soundcloud.com" or host.endswith(".soundcloud.com")
    except ValueError:
        return False


def title_credit(value):
    if not isinstance(value, str):
        return None
    matched = TITLE_CREDIT.fullmatch(value.strip())
    if not matched:
        return None
    performer, title = (part.strip() for part in matched.groups())
    if not any(ch.isalpha() for ch in performer) or not any(ch.isalpha() for ch in title):
        return None
    if title.casefold() in VERSIONS:
        return None
    if performer.casefold().startswith(("prod.", "produced by")):
        return None
    return performer, title


def clean_track(track):
    """Return a shallow copy with normalized title, artist, and uploader metadata.

    Artist is UNKNOWN for an uncredited remote upload. That is deliberately not
    a searchable artist and must not be used as an artist-profile key.
    """
    if not isinstance(track, dict):
        return None
    result = track.copy()
    if not remote_source(result):
        return result
    title = result.get("title", "")
    title = title.strip() if isinstance(title, str) else ""
    uploader = result.get("artist", "")
    uploader = uploader.strip() if isinstance(uploader, str) else ""
    direct = next((
        credit.strip() for key in ("performer", "artist_credit")
        for credit in [result.get(key)]
        if isinstance(credit, str) and credit.strip() and credit.strip() != UNKNOWN
    ), None)
    parsed = title_credit(title)
    if direct:
        result["artist"] = direct
        if parsed and parsed[0].casefold() == direct.casefold():
            result["title"] = parsed[1]
    elif parsed:
        result["artist"] = parsed[0]
        result["title"] = parsed[1]
    else:
        result["artist"] = UNKNOWN
    if uploader:
        result.setdefault("uploader", uploader)
    result["_artist_checked"] = True
    return result


def has_performer(track):
    return (isinstance(track, dict) and isinstance(track.get("artist"), str)
            and bool(track["artist"].strip()) and track["artist"].strip() != UNKNOWN)


def normalize_response(payload):
    """Optional helper for /api/tracks and /api/wave JSON responses.

    Existing app.py can call this immediately before returning its response,
    to fix the web and Windows clients too. It never changes the stream URL.
    """
    if not isinstance(payload, dict):
        return payload
    copy = payload.copy()
    for key in ("tracks", "queue"):
        items = copy.get(key)
        if isinstance(items, list):
            copy[key] = [
                clean_track(item) if isinstance(item, dict) else item
                for item in items
            ]
    return copy
