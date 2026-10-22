"""Lava.top webhook ingestion for Nightwell Music.

Mount with:
    from lava_webhook import router as lava_router
    app.include_router(lava_router)

This module deliberately NEVER grants Premium. Entitlements must be wired
only after matching a verified invoice with an authenticated Nightwell account.
"""
import hashlib
import hmac
import json
import os
import sqlite3
import time
from pathlib import Path

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import JSONResponse

router = APIRouter()
EVENT_TYPES = {
    "payment.success", "payment.failed",
    "subscription.recurring.payment.success",
    "subscription.recurring.payment.failed",
    "subscription.cancelled", "refund.success", "chargeback.initiated",
}
MAX_BODY = 65536

def _database():
    path = Path(os.environ.get("NW_LAVA_DB", "data/lava_webhooks.sqlite3"))
    path.parent.mkdir(parents=True, exist_ok=True)
    return path

def _init(conn):
    conn.execute("""CREATE TABLE IF NOT EXISTS lava_events (
        fingerprint TEXT PRIMARY KEY,
        event_type TEXT NOT NULL,
        invoice_id TEXT,
        received_at INTEGER NOT NULL,
        payload TEXT NOT NULL,
        processing_status TEXT NOT NULL DEFAULT 'pending_review'
    )""")
    conn.execute("CREATE INDEX IF NOT EXISTS lava_events_invoice ON lava_events(invoice_id)")

@router.post("/api/premium/lava/webhook")
async def lava_webhook(request: Request):
    expected = os.environ.get("NW_LAVA_WEBHOOK_KEY", "")
    if len(expected) < 32:
        raise HTTPException(status_code=503, detail="Webhook is not configured")
    supplied = request.headers.get("X-Api-Key", "")
    if not hmac.compare_digest(supplied.encode(), expected.encode()):
        raise HTTPException(status_code=401, detail="Unauthorized")
    length = request.headers.get("content-length")
    if length:
        try:
            if int(length) > MAX_BODY:
                raise HTTPException(status_code=413, detail="Body too large")
        except ValueError:
            raise HTTPException(status_code=400, detail="Invalid content length")
    body = await request.body()
    if len(body) > MAX_BODY:
        raise HTTPException(status_code=413, detail="Body too large")
    try:
        payload = json.loads(body)
    except (UnicodeDecodeError, ValueError):
        raise HTTPException(status_code=400, detail="Invalid JSON")
    if not isinstance(payload, dict):
        raise HTTPException(status_code=400, detail="Expected object")
    event_type = payload.get("eventType", payload.get("event_type", payload.get("event")))
    if not isinstance(event_type, str):
        raise HTTPException(status_code=400, detail="Missing event type")
    # Acknowledge unrecognized events, as recommended by Lava.top.
    if event_type not in EVENT_TYPES:
        return JSONResponse({"ok": True, "ignored": True})
    invoice_id = payload.get("invoiceId", payload.get("invoice_id"))
    if invoice_id is not None and not isinstance(invoice_id, str):
        raise HTTPException(status_code=400, detail="Invalid invoice ID")
    canonical = json.dumps(payload, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    fingerprint = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
    try:
        with sqlite3.connect(_database(), timeout=10) as conn:
            _init(conn)
            conn.execute(
                "INSERT OR IGNORE INTO lava_events "
                "(fingerprint,event_type,invoice_id,received_at,payload) VALUES (?,?,?,?,?)",
                (fingerprint, event_type, invoice_id, int(time.time()), canonical),
            )
    except sqlite3.Error:
        # Return a retryable error rather than losing a paid event.
        raise HTTPException(status_code=503, detail="Storage unavailable")
    return JSONResponse({"ok": True})

