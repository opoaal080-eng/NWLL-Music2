"""Pure search relevance for the Nightwell server; no provider/network access."""
from __future__ import annotations

import json
import re
import unicodedata


def normalize(value: str) -> str:
    text = unicodedata.normalize("NFKC", str(value)).casefold().replace("ё", "е")
    return " ".join(re.findall(r"[^\W_]+", text))


def canonical_title(value: str) -> str:
    """Featuring/promotional credits do not change the recording title.

    Remix/live/version names deliberately remain part of the title. A query
    without an artist cannot determine which artist's equally named song was
    intended; upstream relevance resolves those ties.
    """
    text = unicodedata.normalize("NFKC", str(value))
    featuring = r"(?:feat\.?|ft\.?|featuring|при\s+уч(?:астии|аст)?\.?)"
    text = re.sub(r"(?i)\s*[\(\[【]?\b" + featuring + r"\s+[^\)\]】]+[\)\]】]?", " ", text)
    # Remove only explicit promotion tags, keeping version-bearing sections.
    text = re.sub(
        r"(?i)[\(\[【](?=[^\)\]】]*(?:official|music\s+video|lyrics?|visuali[sz]er|официальн|320\s*k?bps))"
        r"(?![^\)\]】]*(?:remix|ремикс|live|acoustic|cover|karaoke|sped|slowed|remaster))[^\)\]】]*[\)\]】]",
        " ", text)
    text = re.sub(r"(?i)\s+(?:[-–—|:]\s*)?(?:official\s+(?:music\s+)?(?:audio|video)|lyrics?\s+video|visuali[sz]er|320\s*k?bps)\s*$", " ", text)
    return normalize(text)


def rank_track(row, query: str, upstream_ranks: dict[str, int] | None = None) -> tuple:
    """SoundCloud first; rank relevance and provider order within each source.

    Audius only fills a primary-source shortage. No artist names,
    titles, popularity guesses or user-specific boosts are hardcoded.
    """
    needle = canonical_title(query)
    tokens = set(needle.split())
    title = canonical_title(row["title"])
    artist = normalize(row["artist"])
    combined = title + " " + artist
    exact = bool(needle and needle in (title, artist + " " + title, combined))
    title_phrase = bool(needle and needle in title)
    artist_phrase = bool(needle and needle in artist)
    hits = len(tokens & set(combined.split()))
    try:
        rights = row["rights"]
        source = (json.loads(rights) if isinstance(rights, str) else rights).get("source")
    except (TypeError, ValueError, AttributeError, KeyError):
        source = None
    identity = str(row["id"])
    upstream = (upstream_ranks or {}).get(identity, 1_000_000_000)
    source_order = {"soundcloud": 0, "audius": 1}.get(source, 2)
    return (not relevant_track(row,query), source_order, not exact, not title_phrase, not artist_phrase, -hits,
            upstream, title, artist, identity)


def relevant_track(row, query: str) -> bool:
    """A fallback is needed only after a completed search has no relevant SC.

    Matching is canonical so a featuring suffix cannot make a valid title
    disappear. Album-only matches do not stop searching the primary source.
    """
    needle = canonical_title(query)
    if not needle:return False
    text = canonical_title(row["title"]) + " " + normalize(row["artist"])
    return needle in text or set(needle.split()) <= set(text.split())
