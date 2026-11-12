#!/usr/bin/env python3
"""Nightwell metadata indexer: local SQLite search, provider audio stays remote.

Requires Python 3.10+, stdlib only. Fetches *metadata*, never audio.
Not an exhaustive provider catalogue mirror: respects API pagination and quotas.
Run: python catalog_metadata_index.py index --db ./catalog.sqlite --sources audius
"""
from __future__ import annotations

import argparse
import base64
from difflib import SequenceMatcher
import json
import os
import re
import sqlite3
import sys
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

AUDIUS_BASE = "https://api.audius.co/v1"
SC_BASE = "https://api.soundcloud.com"
LAT = dict(zip("абвгдежзийклмнопрстуфхцчшщыэюя",
               ["a", "b", "v", "g", "d", "e", "zh", "z", "i", "y", "k", "l",
                "m", "n", "o", "p", "r", "s", "t", "u", "f", "h", "ts",
                "ch", "sh", "sch", "y", "e", "yu", "ya"]))


def norm(value: str) -> str:
    s = unicodedata.normalize("NFKC", str(value)).lower().replace("ё", "е")
    s = "".join(LAT.get(c, c) if c.isalnum() else " " for c in s)
    return " ".join(s.split())


def open_db(filename: str) -> sqlite3.Connection:
    p = Path(filename).expanduser()
    p.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(str(p))
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA busy_timeout=5000")
    db.executescript("""
    CREATE TABLE IF NOT EXISTS tracks (
        id INTEGER PRIMARY KEY,
        source TEXT NOT NULL,
        source_id TEXT NOT NULL,
        title TEXT NOT NULL,
        artist TEXT NOT NULL,
        duration REAL NOT NULL DEFAULT 0,
        source_url TEXT NOT NULL DEFAULT '',
        cover_url TEXT NOT NULL DEFAULT '',
        updated_at INTEGER NOT NULL,
        UNIQUE(source, source_id)
    );
    CREATE VIRTUAL TABLE IF NOT EXISTS tracks_fts USING fts5(
        title_key, artist_key, tokenize='unicode61 remove_diacritics 2'
    );
    CREATE TABLE IF NOT EXISTS jobs (
        name TEXT PRIMARY KEY,
        cursor TEXT NOT NULL DEFAULT '',
        pages INTEGER NOT NULL DEFAULT 0,
        found INTEGER NOT NULL DEFAULT 0,
        done INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL
    );
    """)
    return db


def upsert_page(db: sqlite3.Connection, source: str, items: list,
                job: str, cursor: str, finished: bool) -> int:
    added = 0
    with db:
        for item in items:
            if not isinstance(item, dict):
                continue
            track = parse_track(source, item)
            if track is None:
                continue
            source_id, title, artist, duration, url, cover = track
            before = db.execute("SELECT id FROM tracks WHERE source=? AND source_id=?",
                                (source, source_id)).fetchone()
            db.execute("""INSERT INTO tracks
                (source,source_id,title,artist,duration,source_url,cover_url,updated_at)
                VALUES(?,?,?,?,?,?,?,?)
                ON CONFLICT(source,source_id) DO UPDATE SET
                title=excluded.title, artist=excluded.artist,
                duration=excluded.duration, source_url=excluded.source_url,
                cover_url=excluded.cover_url, updated_at=excluded.updated_at""",
                (source, source_id, title, artist, duration, url, cover, int(time.time())))
            rowid = before["id"] if before else db.execute(
                "SELECT id FROM tracks WHERE source=? AND source_id=?",
                (source, source_id)).fetchone()["id"]
            if before:
                db.execute("DELETE FROM tracks_fts WHERE rowid=?", (rowid,))
            else:
                added += 1
            db.execute("INSERT INTO tracks_fts(rowid,title_key,artist_key) VALUES(?,?,?)",
                       (rowid, norm(title), norm(artist)))
        db.execute("""INSERT INTO jobs(name,cursor,pages,found,done,updated_at)
            VALUES(?,?,1,?,?,?)
            ON CONFLICT(name) DO UPDATE SET cursor=excluded.cursor,
              pages=jobs.pages+1, found=jobs.found+excluded.found,
              done=excluded.done, updated_at=excluded.updated_at""",
            (job, cursor, len(items), int(finished), int(time.time())))
    return added


def parse_track(source: str, item: dict) -> tuple | None:
    ident = item.get("id")
    title = item.get("title") or ""
    if ident is None or not str(ident).strip() or not title:
        return None
    if source == "audius":
        user = item.get("user") or {}
        artist = item.get("artist_name") or (user.get("name") if isinstance(user, dict) else "") or ""
        duration = item.get("duration") or 0  # Audius uses seconds
        artwork = item.get("artwork") or {}
        cover = (artwork.get("480x480") or artwork.get("150x150") or "") if isinstance(artwork, dict) else ""
        url = item.get("permalink") or ""
        if url and not url.startswith("https://"):
            url = "https://audius.co/" + url.lstrip("/")
    elif source == "soundcloud":
        publisher = item.get("publisher_metadata") or {}
        user = item.get("user") or {}
        artist = (publisher.get("artist") if isinstance(publisher, dict) else "") or (
            user.get("username") if isinstance(user, dict) else "") or ""
        duration = (item.get("duration") or 0) / 1000  # SoundCloud uses milliseconds
        url = item.get("permalink_url") or ""
        cover = item.get("artwork_url") or ""
    else:
        return None
    try:
        seconds = max(0, min(float(duration), 86400))
    except (TypeError, ValueError):
        seconds = 0
    return str(ident)[:120], str(title)[:500], str(artist)[:300], seconds, str(url)[:1500], str(cover)[:1500]


def search_tracks(db: sqlite3.Connection, query: str, limit: int = 25,
                  source: str | None = None) -> list[dict]:
    """Search local metadata; never claim a record is already playable."""
    parts = [p for p in norm(query).split() if len(p) >= 2][:8]
    if not parts:
        return []
    limit = max(1, min(int(limit), 100))
    words = ['"' + p.replace('"', '') + '"*' for p in parts]
    sql = """SELECT t.source,t.source_id,t.title,t.artist,t.duration,
                  t.source_url,t.cover_url,bm25(tracks_fts, 1.8, 1.0) AS rank
             FROM tracks_fts JOIN tracks t ON t.id=tracks_fts.rowid
             WHERE tracks_fts MATCH ?"""
    base: list = []
    if source:
        sql += " AND t.source=?"
        base.append(source)
    sql += " ORDER BY rank LIMIT ?"

    def run(expression: str, size: int) -> list:
        return db.execute(sql, [expression, *base, size]).fetchall()

    exact = run(" AND ".join(words), limit)
    if len(exact) >= limit or len(words) == 1:
        rows = exact
    else:
        # Broader FTS search recovers titles with missing words and gives the
        # client-side fuzzy/NN matcher candidate records to inspect.
        broad = run(" OR ".join(words), min(300, max(80, limit * 8)))
        pooled = {(r["source"], r["source_id"]): r for r in broad}
        pooled.update({(r["source"], r["source_id"]): r for r in exact})
        q = " ".join(parts)
        def relevance(row: sqlite3.Row) -> float:
            title = norm(row["title"])
            artist = norm(row["artist"])
            joined = artist + " " + title
            hits = sum(1 for token in parts if token in joined.split())
            return hits * 1.5 + SequenceMatcher(None, q, joined).ratio()
        rows = sorted(pooled.values(), key=relevance, reverse=True)[:limit]
    return [{
        "source": row["source"], "source_id": row["source_id"],
        "title": row["title"], "artist": row["artist"],
        "duration": row["duration"], "source_url": row["source_url"],
        "cover_url": row["cover_url"]
    } for row in rows]


def soundcloud_token() -> str:
    """Use an existing OAuth token or the documented client-credentials flow."""
    existing = os.getenv("SOUNDCLOUD_ACCESS_TOKEN")
    if existing:
        return existing
    client_id = os.getenv("SOUNDCLOUD_CLIENT_ID")
    client_secret = os.getenv("SOUNDCLOUD_CLIENT_SECRET")
    if not client_id or not client_secret:
        raise SystemExit("Set SOUNDCLOUD_ACCESS_TOKEN or SOUNDCLOUD_CLIENT_ID and SOUNDCLOUD_CLIENT_SECRET.")
    basic = base64.b64encode((client_id + ":" + client_secret).encode()).decode()
    request = urllib.request.Request(
        "https://secure.soundcloud.com/oauth/token",
        data=b"grant_type=client_credentials",
        method="POST",
        headers={"Authorization": "Basic " + basic,
                 "Content-Type": "application/x-www-form-urlencoded",
                 "Accept": "application/json"})
    with urllib.request.urlopen(request, timeout=25) as response:
        data = json.load(response)
    token = data.get("access_token")
    if not isinstance(token, str) or not token:
        raise RuntimeError("SoundCloud OAuth did not return an access token")
    return token


def fetch_json(url: str, token: str | None = None, delay: float = 0.6) -> dict:
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "https" or parsed.hostname not in (
        "api.audius.co", "api.soundcloud.com"):
        raise ValueError("Provider URL is not allowed: " + url[:100])
    headers = {"Accept": "application/json", "User-Agent": "NightwellMetadataIndexer/1.0"}
    if token:
        headers["Authorization"] = ("OAuth " if parsed.hostname == "api.soundcloud.com"
                                    else "Bearer ") + token
    for attempt in range(6):
        try:
            time.sleep(delay)
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=35) as response:
                if int(response.headers.get("Content-Length", 0)) > 8_000_000:
                    raise ValueError("Provider response too large")
                payload = response.read(8_000_001)
                if len(payload) > 8_000_000:
                    raise ValueError("Provider response too large")
                obj = json.loads(payload)
                if not isinstance(obj, dict):
                    raise ValueError("Unexpected provider response")
                return obj
        except urllib.error.HTTPError as exc:
            if exc.code not in (429, 500, 502, 503, 504) or attempt == 5:
                raise
            retry = exc.headers.get("Retry-After", "")
            wait = min(90.0, max(2.0, float(retry) if retry.isdecimal() else 2 ** (attempt + 1)))
            print(f"HTTP {exc.code}, retry after {wait:.0f}s", file=sys.stderr)
            time.sleep(wait)
        except (urllib.error.URLError, TimeoutError):
            if attempt == 5:
                raise
            time.sleep(2 ** (attempt + 1))
    raise RuntimeError("Retries exhausted")


def job_state(db: sqlite3.Connection, name: str) -> tuple[str, bool]:
    row = db.execute("SELECT cursor,done FROM jobs WHERE name=?", (name,)).fetchone()
    return (str(row["cursor"]), bool(row["done"])) if row else ("", False)


def count_tracks(db: sqlite3.Connection) -> int:
    return db.execute("SELECT COUNT(*) FROM tracks").fetchone()[0]


def count_source(db: sqlite3.Connection, source: str) -> int:
    return db.execute("SELECT COUNT(*) FROM tracks WHERE source=?", (source,)).fetchone()[0]


def run_offset_job(db: sqlite3.Connection, name: str, source: str,
                   route: str, params: dict, token: str | None, args) -> None:
    cursor, done = job_state(db, name)
    if done:
        print(f"Already finished: {name}")
        return
    offset = int(cursor or 0)
    page = 0
    while page < args.max_pages and count_source(db, source) < args.max_tracks:
        qs = urllib.parse.urlencode({**params, "limit": args.page_size, "offset": offset})
        response = fetch_json(AUDIUS_BASE + route + "?" + qs, token, args.delay)
        data = response.get("data") or []
        if not isinstance(data, list):
            raise ValueError("Invalid Audius pagination payload")
        next_offset = offset + len(data)
        finished = len(data) < args.page_size
        inserted = upsert_page(db, source, data, name, str(next_offset), finished)
        page += 1
        print(f"{name}: offset={offset}, received={len(data)}, new={inserted}, saved={count_tracks(db)}")
        if finished or not data:
            break
        offset = next_offset


def run_soundcloud_job(db: sqlite3.Connection, name: str, query: str,
                       token: str, args) -> None:
    cursor, done = job_state(db, name)
    if done:
        print(f"Already finished: {name}")
        return
    initial = SC_BASE + "/tracks?" + urllib.parse.urlencode({
        "q": query, "access": "playable", "limit": args.page_size,
        "linked_partitioning": "true"})
    url = cursor or initial
    page = 0
    while page < args.max_pages and count_source(db, "soundcloud") < args.max_tracks and url:
        response = fetch_json(url, token, args.delay)
        items = response.get("collection") or []
        if not isinstance(items, list):
            raise ValueError("Invalid SoundCloud pagination payload")
        following = response.get("next_href") or ""
        if following == url:
            raise ValueError("SoundCloud next_href loop")
        finished = not following or not items
        inserted = upsert_page(db, "soundcloud", items, name, following, finished)
        page += 1
        print(f"{name}: received={len(items)}, new={inserted}, saved={count_tracks(db)}")
        url = following
        if finished:
            break


def seeds(args) -> list[str]:
    entries = list(args.seed or [])
    if args.seed_file:
        entries += Path(args.seed_file).read_text(encoding="utf-8-sig").splitlines()
    unique = dict.fromkeys(q.strip() for q in entries if q.strip() and not q.lstrip().startswith("#"))
    return [q[:200] for q in unique][:500]


def index(db: sqlite3.Connection, args) -> None:
    queries = seeds(args)
    if args.sources in ("audius", "both"):
        token = os.getenv("AUDIUS_API_KEY")
        # Official Audius endpoints are limited/paginated. No "export all" API
        # is assumed; rerun to resume safely from the last committed page.
        run_offset_job(db, "audius:latest", "audius", "/tracks/latest", {},
                       token, args)
        for q in queries:
            if count_source(db, "audius") >= args.max_tracks:
                break
            run_offset_job(db, "audius:search:" + norm(q), "audius",
                           "/tracks/search", {"query": q}, token, args)
    if args.sources in ("soundcloud", "both"):
        if not args.allow_soundcloud_metadata_store:
            print("SoundCloud indexing disabled: confirm your API usage/storage rights "
                  "and pass --allow-soundcloud-metadata-store.", file=sys.stderr)
            return
        token = soundcloud_token()
        if not queries:
            print("No SoundCloud seed queries. Use --seed or --seed-file.", file=sys.stderr)
        for q in queries:
            if count_source(db, "soundcloud") >= args.max_tracks:
                break
            run_soundcloud_job(db, "soundcloud:search:" + norm(q), q, token, args)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", default="./nightwell_catalog.sqlite")
    sub = parser.add_subparsers(dest="command", required=True)
    idx = sub.add_parser("index", help="Fetch metadata with resumable checkpoints")
    idx.add_argument("--db", default="./nightwell_catalog.sqlite")
    idx.add_argument("--sources", choices=["audius", "soundcloud", "both"], default="audius")
    idx.add_argument("--seed", action="append", help="Artist/title/genre query (repeatable)")
    idx.add_argument("--seed-file", help="Text file with one query per line")
    idx.add_argument("--max-tracks", type=int, default=50000)
    idx.add_argument("--max-pages", type=int, default=250, help="Pages per job per run")
    idx.add_argument("--page-size", type=int, default=50)
    idx.add_argument("--delay", type=float, default=0.8)
    idx.add_argument("--allow-soundcloud-metadata-store", action="store_true",
                     help="You verified storage is permitted by your SoundCloud API terms")
    look = sub.add_parser("search", help="Query the local full-text index")
    look.add_argument("--db", default="./nightwell_catalog.sqlite")
    look.add_argument("query")
    look.add_argument("--limit", type=int, default=20)
    look.add_argument("--source", choices=["audius", "soundcloud"])
    stats = sub.add_parser("stats")
    stats.add_argument("--db", default="./nightwell_catalog.sqlite")
    args = parser.parse_args()
    if args.command == "index":
        if not 1 <= args.page_size <= 100 or args.max_pages < 1 or args.max_tracks < 1 or args.delay < 0.3:
            parser.error("Invalid limits: page-size 1..100, max-pages/tracks >0, delay >=0.3s")
    with open_db(args.db) as db:
        if args.command == "index":
            index(db, args)
        elif args.command == "search":
            print(json.dumps({"tracks": search_tracks(db, args.query, args.limit,
                                                      args.source)}, ensure_ascii=False, indent=2))
        elif args.command == "stats":
            rows = db.execute("SELECT source,COUNT(*) AS n FROM tracks GROUP BY source").fetchall()
            jobs = db.execute("SELECT name,cursor,pages,done FROM jobs ORDER BY name").fetchall()
            print(json.dumps({"total": count_tracks(db),
                              "sources": {r["source"]: r["n"] for r in rows},
                              "jobs": [dict(j) for j in jobs]}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
