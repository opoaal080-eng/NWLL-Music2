"""HTTP integration tests for account quotas and a three-account Premium family.

The x-test-* headers below belong only to this synthetic host adapter; production
identity and session keys must come from the existing authenticated server.
"""
from __future__ import annotations

import asyncio
import json
import re
import tempfile
import time
import unittest
from pathlib import Path

import httpx
from fastapi import FastAPI, HTTPException, Request

from account_access import install


class AccountAccessApiTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.now = time.time()
        self.paid: dict[str, float | None] = {}
        self.unavailable: set[str] = set()
        self.app = FastAPI()

        def identity(request: Request):
            account = request.headers.get("x-test-user")
            if not account:
                raise HTTPException(401, "Authentication required")
            return account

        def direct_premium(account: str):
            if account in self.unavailable:
                raise RuntimeError("Synthetic subscription-store outage")
            return {"premium": account in self.paid, "expires_at": self.paid.get(account)}

        def csrf(request: Request):
            return request.headers.get("x-csrf-token") == "test-csrf"

        def session_key(request: Request):
            return request.headers.get("x-test-session")

        @self.app.get("/api/me")
        async def me(request: Request):
            account = identity(request)
            return {"user": {"id": account}, "csrf": "test-csrf"}

        @self.app.get("/api/protected")
        async def protected(request: Request):
            identity(request)
            return {"ok": True}

        @self.app.get("/stream/track")
        async def stream(request: Request):
            identity(request)
            return {"ok": True}

        @self.app.get("/api/premium-feature")
        async def premium_feature(request: Request):
            self.controller.require_premium(identity(request))
            return {"ok": True}

        self.database_path = Path(self.temporary.name) / "access.sqlite3"
        self.controller = install(
            self.app, identity, database_path=self.database_path,
            direct_premium=direct_premium, csrf_verifier=csrf,
            session_key=session_key, public_origin="https://music.nightwell.fun",
            enforce=True, clock=lambda: self.now,
        )

    def headers(self, account=None, *, session=None, csrf=False, token=None, device_id=None, platform=None):
        result = {}
        if account is not None:
            result["x-test-user"] = account
            result["x-test-session"] = session or account + "-management"
        if csrf:
            result["x-csrf-token"] = "test-csrf"
        if token is not None:
            result["x-nw-device-token"] = token
        if device_id is not None:
            result["x-nw-device-id"] = device_id
        if platform is not None:
            result["x-nw-device-platform"] = platform
        return result

    async def request(self, method, path, account=None, *, session=None, csrf=False,
                      token=None, device_id=None, platform=None, **kwargs):
        # A separate cookie jar per logical request prevents one test-device's
        # HttpOnly credential from silently authenticating another test-device.
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=self.app),
                                     base_url="https://nightwell.test") as client:
            return await client.request(method, path, headers=self.headers(
                account, session=session, csrf=csrf, token=token,
                device_id=device_id, platform=platform), **kwargs)

    async def register(self, account, number, *, token=None, device_id=None, platform="ios", session=None):
        body = {"name": f"Device {number}", "platform": platform}
        if device_id is not None:
            body["device_id"] = device_id
        if token is not None:
            body["device_token"] = token
        return await self.request("POST", "/api/devices/register", account,
                                  session=session or f"{account}-device-{number}", csrf=True,
                                  token=token, device_id=device_id, platform=platform, json=body)

    def success(self, response):
        self.assertIn(response.status_code, (200, 201), response.text)
        return response.json()

    @staticmethod
    def row_id(row):
        return row.get("id", row.get("device_id"))

    async def invitation(self, account="owner"):
        return self.success(await self.request("POST", "/api/family/invitations", account, csrf=True))

    async def accept(self, account, token):
        return await self.request("POST", "/api/family/invitations/accept", account,
                                  csrf=True, json={"token": token})

    async def test_recovery_and_entitlement_routes_require_authentication(self):
        for path in ("/api/account/access", "/api/devices", "/api/family", "/api/protected", "/stream/track"):
            self.assertEqual((await self.request("GET", path)).status_code, 401, path)
        self.assertEqual((await self.request("POST", "/api/devices/register", csrf=True,
                                             json={"platform": "web", "name": "Browser"})).status_code, 401)

    async def test_free_account_has_two_device_slots(self):
        first = self.success(await self.register("alice", 1))
        second = self.success(await self.register("alice", 2))
        self.assertEqual(first["limit"], 2)
        self.assertNotEqual(first["device_token"], second["device_token"])
        denied = await self.register("alice", 3)
        self.assertEqual(denied.status_code, 409, denied.text)
        devices = self.success(await self.request("GET", "/api/devices", "alice"))
        self.assertEqual(devices["limit"], 2)
        self.assertEqual(len(devices["devices"]), 2)

    async def test_premium_account_has_five_slots_and_no_sixth(self):
        self.paid["alice"] = self.now + 3600
        for number in range(1, 6):
            registered = self.success(await self.register("alice", number))
            self.assertEqual(registered["limit"], 5)
        denied = await self.register("alice", 6)
        self.assertEqual(denied.status_code, 409, denied.text)
        self.assertEqual(len(self.success(await self.request("GET", "/api/devices", "alice"))["devices"]), 5)

    async def test_no_platform_or_id_header_bypasses_device_credential(self):
        device = self.success(await self.register("alice", 1))
        for platform in (None, "web", "unknown"):
            for path in ("/api/protected", "/stream/track"):
                denied = await self.request("GET", path, "alice", session="alice-device-1",
                                             device_id=device["device_id"], platform=platform)
                self.assertIn(denied.status_code, (401, 403, 426), denied.text)
        allowed = await self.request("GET", "/api/protected", "alice", session="alice-device-1",
                                     token=device["device_token"])
        self.assertEqual(allowed.status_code, 200, allowed.text)

    async def test_cross_account_token_is_not_an_account_identity(self):
        device = self.success(await self.register("alice", 1))
        denied = await self.request("GET", "/api/protected", "bob", session="bob-device-1",
                                     token=device["device_token"], device_id=device["device_id"])
        self.assertIn(denied.status_code, (401, 403), denied.text)
        bob = self.success(await self.request("GET", "/api/devices", "bob"))
        self.assertEqual(bob["devices"], [])

    async def test_guessing_existing_id_cannot_claim_a_slot(self):
        device = self.success(await self.register("alice", 1))
        denied = await self.register("alice", 2, device_id=device["device_id"])
        self.assertIn(denied.status_code, (401, 403, 409), denied.text)
        relogin = self.success(await self.register("alice", 2,
                           token=device["device_token"], device_id=device["device_id"]))
        self.assertEqual(relogin["device_id"], device["device_id"])
        self.assertEqual(len(self.success(await self.request("GET", "/api/devices", "alice"))["devices"]), 1)

    async def test_removed_device_revokes_all_bound_sessions(self):
        device = self.success(await self.register("alice", 1))
        self.success(await self.register("alice", 2, token=device["device_token"], device_id=device["device_id"]))
        removed = await self.request("DELETE", "/api/devices/" + device["device_id"], "alice", csrf=True)
        self.assertEqual(removed.status_code, 200, removed.text)
        for number in (1, 2):
            blocked = await self.request("GET", "/api/protected", "alice", session=f"alice-device-{number}",
                                         token=device["device_token"])
            self.assertEqual(blocked.status_code, 401, blocked.text)
            reregister = await self.register("alice", number)
            self.assertEqual(reregister.status_code, 401, reregister.text)
        # A genuinely new login session may register a new device after capacity
        # is freed, but the old session cannot undo a remote sign-out.
        self.success(await self.register("alice", 3))

    async def test_other_account_cannot_remove_an_owned_device(self):
        device = self.success(await self.register("alice", 1))
        denied = await self.request("DELETE", "/api/devices/" + device["device_id"], "bob", csrf=True)
        self.assertIn(denied.status_code, (403, 404), denied.text)
        self.assertEqual(len(self.success(await self.request("GET", "/api/devices", "alice"))["devices"]), 1)

    async def test_device_mutations_require_csrf(self):
        device = self.success(await self.register("alice", 1))
        for method, path, body in (
            ("POST", "/api/devices/register", {"name": "Another", "platform": "web"}),
            ("DELETE", "/api/devices/" + device["device_id"], None),
        ):
            response = await self.request(method, path, "alice", json=body)
            self.assertEqual(response.status_code, 403, response.text)

    async def test_concurrent_registration_cannot_overbook_free_slots(self):
        responses = await asyncio.gather(*(self.register("alice", n) for n in range(1, 7)))
        self.assertEqual(sum(r.status_code in (200, 201) for r in responses), 2,
                         [(r.status_code, r.text) for r in responses])
        self.assertTrue(all(r.status_code in (200, 201, 409) for r in responses))
        devices = self.success(await self.request("GET", "/api/devices", "alice"))
        self.assertEqual(len(devices["devices"]), 2)

    async def test_expiry_keeps_records_and_blocks_excess_devices_stably(self):
        self.paid["alice"] = self.now + 60
        tokens = {}
        for number in range(1, 6):
            record = self.success(await self.register("alice", number))
            tokens[record["device_id"]] = (record["device_token"], f"alice-device-{number}")
            self.now += 1
        self.now += 120
        listing = self.success(await self.request("GET", "/api/devices", "alice"))
        self.assertEqual(listing["limit"], 2)
        self.assertEqual(len(listing["devices"]), 5)
        blocked = [row for row in listing["devices"] if row["blocked"]]
        self.assertEqual(len(blocked), 3)
        for row in blocked:
            token, session = tokens[self.row_id(row)]
            denied = await self.request("GET", "/api/protected", "alice", session=session, token=token)
            self.assertEqual(denied.status_code, 409, denied.text)
        again = self.success(await self.request("GET", "/api/devices", "alice"))
        self.assertEqual({self.row_id(r) for r in again["devices"] if r["blocked"]},
                         {self.row_id(r) for r in blocked})
        self.paid["alice"] = self.now + 3600
        renewed = self.success(await self.request("GET", "/api/devices", "alice"))
        self.assertFalse(any(row["blocked"] for row in renewed["devices"]))

    async def test_subscription_store_error_is_503_and_does_not_drop_records(self):
        self.paid["alice"] = self.now + 3600
        device = self.success(await self.register("alice", 1))
        self.unavailable.add("alice")
        for method, path, kwargs in (
            ("GET", "/api/account/access", {}),
            ("POST", "/api/devices/register", {"csrf": True, "json": {"platform": "web", "name": "Browser"}}),
            ("GET", "/api/protected", {"session": "alice-device-1", "token": device["device_token"]}),
        ):
            response = await self.request(method, path, "alice", **kwargs)
            self.assertEqual(response.status_code, 503, response.text)
        self.unavailable.clear()
        listing = self.success(await self.request("GET", "/api/devices", "alice"))
        self.assertEqual(len(listing["devices"]), 1)
        self.assertEqual(listing["limit"], 5)

    async def test_owner_can_invite_two_people_at_same_existing_subscription(self):
        self.paid["owner"] = self.now + 3600
        first = await self.invitation()
        second = await self.invitation()
        self.assertIn("#invite=" + first["token"], first["invite_url"])
        self.assertTrue(first["invite_url"].startswith("https://music.nightwell.fun/family#"))
        self.assertAlmostEqual(first["expires_at"] - self.now, 7 * 24 * 3600, delta=1)
        denied = await self.request("POST", "/api/family/invitations", "owner", csrf=True)
        self.assertEqual(denied.status_code, 409, denied.text)
        self.success(await self.accept("alice", first["token"]))
        self.success(await self.accept("bob", second["token"]))
        family = self.success(await self.request("GET", "/api/family", "owner"))
        if "family" in family:
            family = family["family"]
        self.assertEqual(family["member_count"], 3)
        self.assertEqual({r["account_id"] for r in family["members"]}, {"owner", "alice", "bob"})
        self.assertEqual(set(self.paid), {"owner"}, "Joining must not create paid records or change price")

    async def test_family_premium_grants_five_slots_per_member_not_shared_total(self):
        self.paid["owner"] = self.now + 3600
        for account in ("alice", "bob"):
            invite = await self.invitation()
            self.success(await self.accept(account, invite["token"]))
        for account in ("owner", "alice", "bob"):
            access = self.success(await self.request("GET", "/api/account/access", account))
            self.assertTrue(access["premium"])
            self.assertEqual(access["device_limit"], 5)
            for number in range(1, 6):
                self.success(await self.register(account, number))
            self.assertEqual((await self.register(account, 6)).status_code, 409)

    async def test_only_direct_paid_owner_can_create_invitations(self):
        free = await self.request("POST", "/api/family/invitations", "alice", csrf=True)
        self.assertIn(free.status_code, (402, 403), free.text)
        self.paid["owner"] = self.now + 3600
        invite = await self.invitation()
        self.success(await self.accept("alice", invite["token"]))
        denied = await self.request("POST", "/api/family/invitations", "alice", csrf=True)
        self.assertIn(denied.status_code, (402, 403, 409), denied.text)
        # Even an independently paying member must first leave the old family.
        self.paid["alice"] = self.now + 3600
        denied = await self.request("POST", "/api/family/invitations", "alice", csrf=True)
        self.assertIn(denied.status_code, (403, 409), denied.text)

    async def test_acceptance_is_single_use_and_retry_by_member_is_idempotent(self):
        self.paid["owner"] = self.now + 3600
        invite = await self.invitation()
        self.success(await self.accept("alice", invite["token"]))
        self.success(await self.accept("alice", invite["token"]))
        replay = await self.accept("bob", invite["token"])
        self.assertEqual(replay.status_code, 409, replay.text)
        family = self.success(await self.request("GET", "/api/family", "owner"))
        family = family.get("family", family)
        self.assertEqual(family["member_count"], 2)

    async def test_invalid_self_accept_does_not_consume_invitation(self):
        self.paid["owner"] = self.now + 3600
        invite = await self.invitation()
        denied = await self.accept("owner", invite["token"])
        self.assertIn(denied.status_code, (400, 409), denied.text)
        self.success(await self.accept("alice", invite["token"]))

    async def test_account_cannot_join_two_families_or_transfer_ownership(self):
        self.paid["owner"] = self.now + 3600
        self.paid["other-owner"] = self.now + 3600
        first = await self.invitation()
        self.success(await self.accept("alice", first["token"]))
        second = await self.invitation("other-owner")
        denied = await self.accept("alice", second["token"])
        self.assertEqual(denied.status_code, 409, denied.text)
        self.success(await self.accept("bob", second["token"]))
        owner_denied = await self.accept("owner", (await self.invitation("other-owner"))["token"])
        self.assertEqual(owner_denied.status_code, 409, owner_denied.text)

    async def test_pending_invite_can_be_revoked_to_release_a_reserved_slot(self):
        self.paid["owner"] = self.now + 3600
        first = await self.invitation()
        await self.invitation()
        removed = await self.request("DELETE", "/api/family/invitations/" + first["invite_id"], "owner", csrf=True)
        self.assertEqual(removed.status_code, 200, removed.text)
        await self.invitation()
        rejected = await self.accept("alice", first["token"])
        self.assertIn(rejected.status_code, (404, 409, 410), rejected.text)

    async def test_expired_invites_free_slots_without_acceptance(self):
        self.paid["owner"] = self.now + 30 * 24 * 3600
        first = await self.invitation()
        await self.invitation()
        self.now += 7 * 24 * 3600 + 1
        expired = await self.accept("alice", first["token"])
        self.assertIn(expired.status_code, (404, 409, 410), expired.text)
        await self.invitation()

    async def test_owner_expiry_revokes_family_entitlement_on_next_request(self):
        self.paid["owner"] = self.now + 60
        invite = await self.invitation()
        self.success(await self.accept("alice", invite["token"]))
        device = self.success(await self.register("alice", 1))
        self.assertTrue(self.success(await self.request("GET", "/api/account/access", "alice"))["premium"])
        self.now += 120
        access = self.success(await self.request("GET", "/api/account/access", "alice"))
        self.assertFalse(access["premium"])
        self.assertEqual(access["device_limit"], 2)
        denied = await self.request("GET", "/api/premium-feature", "alice", session="alice-device-1", token=device["device_token"])
        self.assertIn(denied.status_code, (402, 403), denied.text)
        family = self.success(await self.request("GET", "/api/family", "alice"))
        self.assertIsNotNone(family.get("family", family))
        self.paid["owner"] = self.now + 60
        self.assertTrue(self.success(await self.request("GET", "/api/account/access", "alice"))["premium"])

    async def test_owner_outage_is_not_silently_a_free_family(self):
        self.paid["owner"] = self.now + 3600
        invite = await self.invitation()
        self.success(await self.accept("alice", invite["token"]))
        self.unavailable.add("owner")
        response = await self.request("GET", "/api/account/access", "alice")
        self.assertEqual(response.status_code, 503, response.text)
        self.unavailable.clear()
        self.assertTrue(self.success(await self.request("GET", "/api/account/access", "alice"))["premium"])

    async def test_leaving_or_removal_preserves_own_paid_subscription(self):
        self.paid["owner"] = self.now + 3600
        self.paid["alice"] = self.now + 7200
        invite = await self.invitation()
        self.success(await self.accept("alice", invite["token"]))
        self.assertEqual((await self.request("POST", "/api/family/leave", "alice", csrf=True)).status_code, 200)
        access = self.success(await self.request("GET", "/api/account/access", "alice"))
        self.assertTrue(access["premium"])
        self.assertEqual(access["device_limit"], 5)
        self.assertEqual(self.paid["alice"], self.now + 7200)
        second = await self.invitation()
        self.success(await self.accept("alice", second["token"]))
        self.assertEqual((await self.request("DELETE", "/api/family/members/alice", "owner", csrf=True)).status_code, 200)
        self.assertTrue(self.success(await self.request("GET", "/api/account/access", "alice"))["premium"])

    async def test_member_cannot_remove_or_revoke_another_owners_resources(self):
        self.paid["owner"] = self.now + 3600
        first = await self.invitation()
        second = await self.invitation()
        self.success(await self.accept("alice", first["token"]))
        for method, path in (
            ("DELETE", "/api/family/invitations/" + second["invite_id"]),
            ("DELETE", "/api/family/members/owner"),
            ("DELETE", "/api/family"),
        ):
            denied = await self.request(method, path, "alice", csrf=True)
            self.assertIn(denied.status_code, (403, 404, 409), denied.text)
        self.success(await self.accept("bob", second["token"]))

    async def test_family_mutations_require_csrf(self):
        self.paid["owner"] = self.now + 3600
        invite = await self.invitation()
        for method, path, account, body in (
            ("POST", "/api/family/invitations", "owner", None),
            ("POST", "/api/family/invitations/accept", "alice", {"token": invite["token"]}),
            ("DELETE", "/api/family/invitations/" + invite["invite_id"], "owner", None),
            ("POST", "/api/family/leave", "owner", None),
            ("DELETE", "/api/family", "owner", None),
        ):
            denied = await self.request(method, path, account, json=body)
            self.assertEqual(denied.status_code, 403, denied.text)

    async def test_preview_does_not_join_or_expose_owner_identity(self):
        self.paid["owner-secret-account"] = self.now + 3600
        invite = await self.invitation("owner-secret-account")
        preview = self.success(await self.request("POST", "/api/family/invitations/preview", json={"token": invite["token"]}))
        self.assertTrue(preview["available"])
        serialized = json.dumps(preview)
        self.assertNotIn("owner-secret-account", serialized)
        self.assertNotIn("owner_id", preview)
        self.assertNotIn("email", serialized.lower())
        listing = self.success(await self.request("GET", "/api/family", "owner-secret-account"))
        listing = listing.get("family", listing)
        self.assertEqual(listing["member_count"], 1)
        self.success(await self.accept("alice", invite["token"]))

    async def test_family_page_uses_nonce_and_does_not_join_on_get(self):
        self.paid["owner"] = self.now + 3600
        invite = await self.invitation()
        page = await self.request("GET", "/family")
        self.assertEqual(page.status_code, 200, page.text)
        self.assertIn("text/html", page.headers.get("content-type", ""))
        self.assertEqual(page.headers.get("referrer-policy"), "no-referrer")
        policy = page.headers.get("content-security-policy", "")
        match = re.search(r"'nonce-([^']+)'", policy)
        self.assertIsNotNone(match, policy)
        self.assertIn('nonce="' + match.group(1) + '"', page.text)
        self.assertNotIn("'unsafe-inline'", policy)
        self.assertNotIn(invite["token"], page.text)
        family = self.success(await self.request("GET", "/api/family", "owner"))
        family = family.get("family", family)
        self.assertEqual(family["member_count"], 1)

    async def test_premium_response_keeps_personal_billing_fields(self):
        self.paid["owner"] = self.now + 3600
        invite = await self.invitation()
        self.success(await self.accept("alice", invite["token"]))
        original = {"premium": False, "expires_at": None, "price": 150,
                    "invoice_id": "alice-own-invoice", "auto_renew": False}
        result = self.controller.premium_response("alice", original)
        self.assertTrue(result["premium"])
        self.assertEqual(result["price"], 150)
        self.assertEqual(result["invoice_id"], "alice-own-invoice")
        self.assertFalse(result["auto_renew"])
        self.assertFalse(original["premium"], "The adapter must not mutate the original response")


    async def test_bound_session_cannot_switch_to_another_device_token(self):
        first = self.success(await self.register("alice", 1))
        second = self.success(await self.register("alice", 2))
        denied = await self.request("GET", "/api/protected", "alice", session="alice-device-1",
                                     token=second["device_token"])
        self.assertEqual(denied.status_code, 401, denied.text)
        allowed = await self.request("GET", "/api/protected", "alice", session="alice-device-1",
                                      token=first["device_token"])
        self.assertEqual(allowed.status_code, 200, allowed.text)

    async def test_web_device_uses_secure_httponly_cookie(self):
        headers = self.headers("alice", session="alice-web-session", csrf=True)
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=self.app),
                                     base_url="https://nightwell.test", headers=headers) as client:
            registered = await client.post("/api/devices/register", json={"platform": "web", "name": "Browser"})
            self.success(registered)
            cookie = registered.headers.get("set-cookie", "").lower()
            self.assertIn("nw_device_token=", cookie)
            self.assertIn("httponly", cookie)
            self.assertIn("secure", cookie)
            self.assertIn("samesite=lax", cookie)
            self.assertEqual((await client.get("/api/protected")).status_code, 200)

    async def test_switching_web_account_does_not_reuse_the_old_accounts_cookie(self):
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=self.app),
                                     base_url="https://nightwell.test",
                                     headers=self.headers("alice", session="alice-web", csrf=True)) as client:
            first = self.success(await client.post("/api/devices/register", json={"platform": "web", "name": "Alice browser"}))
            client.headers.update(self.headers("bob", session="bob-web", csrf=True))
            second = self.success(await client.post("/api/devices/register", json={"platform": "web", "name": "Bob browser"}))
            self.assertNotEqual(first["device_token"], second["device_token"])
            self.assertEqual((await client.get("/api/protected")).status_code, 200)
        for account in ("alice", "bob"):
            listing = self.success(await self.request("GET", "/api/devices", account))
            self.assertEqual(len(listing["devices"]), 1)

    async def test_explicit_bad_credential_is_not_hidden_by_a_valid_browser_cookie(self):
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=self.app),
                                     base_url="https://nightwell.test",
                                     headers=self.headers("alice", session="alice-web", csrf=True)) as client:
            self.success(await client.post("/api/devices/register", json={"platform": "web", "name": "Browser"}))
            denied = await client.post("/api/devices/register", json={"platform": "web", "name": "Browser"},
                                       headers={"x-nw-device-token": "wrong" * 10})
            self.assertEqual(denied.status_code, 401, denied.text)

    async def test_device_registration_rejects_non_string_platforms(self):
        for platform in (["ios"], {"name": "ios"}, 1, True, None):
            response = await self.request("POST", "/api/devices/register", "alice", csrf=True,
                                          json={"platform": platform, "name": "Invalid device"})
            self.assertEqual(response.status_code, 400, response.text)
        listing = self.success(await self.request("GET", "/api/devices", "alice"))
        self.assertEqual(listing["devices"], [])

if __name__ == "__main__":
    unittest.main()
