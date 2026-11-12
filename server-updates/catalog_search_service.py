#!/usr/bin/env python3
"""Local metadata search sidecar for Nightwell Music (no provider calls).

Bind to loopback only. The main music server is responsible for resolving
source/source_id into its playable Track IDs and fetching audio on demand.
"""
from __future__ import annotations

import argparse
import json
import sqlite3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

from catalog_metadata_index import search_tracks


class Handler(BaseHTTPRequestHandler):
    server: "SearchServer"

    def reply(self, status: int, payload: dict) -> None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "private, max-age=30")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:
        parsed = urlsplit(self.path)
        if parsed.path == "/health":
            self.reply(200, {"ok": True, "kind": "metadata-only"})
            return
        if parsed.path != "/catalog/search":
            self.reply(404, {"error": "not_found"})
            return
        params = parse_qs(parsed.query, keep_blank_values=False)
        query = (params.get("q") or [""])[0][:200].strip()
        source = (params.get("source") or [""])[0]
        if source not in ("", "audius", "soundcloud"):
            self.reply(400, {"error": "invalid_source"})
            return
        try:
            limit = max(1, min(50, int((params.get("limit") or ["20"])[0])))
        except (ValueError, TypeError):
            self.reply(400, {"error": "invalid_limit"})
            return
        if not query:
            self.reply(200, {"tracks": [], "metadata_only": True})
            return
        try:
            db = sqlite3.connect(self.server.db_path, timeout=5)
            db.row_factory = sqlite3.Row
            db.execute("PRAGMA query_only=ON")
            try:
                tracks = search_tracks(db, query, limit, source or None)
            finally:
                db.close()
            self.reply(200, {"tracks": tracks, "metadata_only": True})
        except (sqlite3.Error, ValueError):
            self.reply(503, {"error": "index_unavailable"})

    def do_POST(self) -> None:
        self.reply(405, {"error": "read_only"})


class SearchServer(ThreadingHTTPServer):
    def __init__(self, address, handler, db_path: str):
        super().__init__(address, handler)
        self.db_path = db_path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", default="./nightwell_catalog.sqlite")
    parser.add_argument("--port", type=int, default=8099)
    args = parser.parse_args()
    path = Path(args.db).expanduser().resolve()
    if not path.is_file():
        parser.error("SQLite index not found. Run catalog_metadata_index.py index first.")
    if not 1024 <= args.port <= 65535:
        parser.error("Invalid port")
    with SearchServer(("127.0.0.1", args.port), Handler, str(path)) as server:
        print(f"Nightwell metadata lookup listening on http://127.0.0.1:{args.port}/catalog/search")
        try:
            server.serve_forever(poll_interval=0.5)
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
