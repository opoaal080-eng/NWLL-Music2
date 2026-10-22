# Lava.top webhook for Nightwell Music

Status: secure webhook inbox implemented; **automatic Premium activation NOT enabled**.

The current repo contains iOS/Android/Windows clients but not the running
FastAPI server, so this is a server-side integration module to copy to the
server installation, not a live deployment.

1. Copy `server/lava_webhook.py` alongside your FastAPI `app.py`.
2. Add `from lava_webhook import router as lava_router` and
   `app.include_router(lava_router)` after creating the FastAPI app.
3. Set `NW_LAVA_WEBHOOK_KEY` to a private random 32+ character secret.
   Set `NW_LAVA_DB` to a persistent writable SQLite path. Do not commit secrets.
4. On Lava.top: Integrations > API > Add webhook. Set URL to
   `https://music.nightwell.fun/api/premium/lava/webhook`.
   Choose API Key authorization and enter the same private webhook secret.
   Enable payment.success, renewal success, failed payment, cancellation,
   refunds and chargeback events as appropriate.
5. Confirm delivery in Lava.top webhook history and inspect database
   `lava_events`. Unknown event types return 200; invalid keys return 401.
6. Before activating Premium, implement *verified invoice -> account*
   reconciliation against the actual `premium.sqlite3` schema and confirm
   the payload format using an authentic webhook in staging. Use invoice IDs
   for idempotency, validate the configured offer/product, and handle refunds.
   Do not grant access based only on a redirect URL, buyer-provided email,
   or the existence of a webhook notification.

The direct product URL in the iOS client does not identify the Nightwell
account that paid. For automatic entitlement linking, create a checkout
invoice server-side for the currently logged-in account and persist the
invoice-to-user association before redirecting to Lava.top.

Documentation: https://developers.lava.top/en
