"""API regression tests: free/Premium limits and owner isolation."""
import tempfile
import unittest
from pathlib import Path

import httpx
from fastapi import FastAPI, HTTPException, Request

from account_devices import install


def device(number):
    return "ios_" + ("%032x" % number)


class DeviceRegistryTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.premium = set()
        self.app = FastAPI()

        @self.app.get("/api/music")
        async def music():
            return {"ok": True}

        @self.app.get("/api/me")
        async def me():
            return {"user": None}

        def identify(request: Request):
            account = request.headers.get("x-test-account")
            if not account:
                raise HTTPException(401, "authentication required")
            return account

        def verify_csrf(request: Request):
            return request.headers.get("x-csrf-token") == "test-csrf"

        install(self.app, identify, Path(temporary.name) / "registry.sqlite3",
                lambda account: account in self.premium, verify_csrf)
        self.client = httpx.AsyncClient(
            transport=httpx.ASGITransport(app=self.app), base_url="http://test.local")

    async def asyncTearDown(self):
        await self.client.aclose()

    def headers(self, account, number=1, csrf=False):
        headers = {
            "x-test-account": account,
            "x-nw-device-id": device(number),
            "x-nw-device-platform": "ios",
        }
        if csrf:
            headers["x-csrf-token"] = "test-csrf"
        return headers

    async def register(self, account, number):
        return await self.client.post("/api/devices/register",
            headers=self.headers(account, number, csrf=True),
            json={"device_id": device(number), "platform": "ios",
                  "name": "iPhone " + str(number)})

    async def test_free_limit_and_reclaiming_slot(self):
        self.assertEqual((await self.register("alice", 1)).status_code, 200)
        self.assertEqual((await self.register("alice", 2)).status_code, 200)
        denied = await self.register("alice", 3)
        self.assertEqual(denied.status_code, 409)
        self.assertEqual(denied.json()["code"], "device_limit")
        self.assertEqual((await self.client.get("/api/music",
            headers=self.headers("alice", 3))).status_code, 409)
        self.assertEqual((await self.client.get("/api/music",
            headers=self.headers("alice", 1))).status_code, 200)
        removed = await self.client.delete("/api/devices/" + device(1),
            headers=self.headers("alice", 2, csrf=True))
        self.assertEqual(removed.status_code, 200)
        self.assertEqual((await self.register("alice", 3)).status_code, 200)

    async def test_premium_five_and_downgrade(self):
        self.premium.add("alice")
        for index in range(1, 6):
            self.assertEqual((await self.register("alice", index)).status_code, 200)
        self.assertEqual((await self.register("alice", 6)).status_code, 409)
        listing = await self.client.get("/api/devices", headers=self.headers("alice", 5))
        self.assertEqual(listing.json()["limit"], 5)
        self.assertEqual(listing.json()["count"], 5)
        self.premium.clear()
        listing = await self.client.get("/api/devices", headers=self.headers("alice", 5))
        self.assertEqual(listing.json()["limit"], 2)
        self.assertEqual(sum(item["blocked"] for item in listing.json()["devices"]), 3)
        self.assertEqual((await self.client.get("/api/music",
            headers=self.headers("alice", 1))).status_code, 409)

    async def test_devices_are_isolated_by_authenticated_account(self):
        self.assertEqual((await self.register("alice", 1)).status_code, 200)
        self.assertEqual((await self.register("bob", 1)).status_code, 200)
        denied = await self.client.delete("/api/devices/" + device(1),
            headers=self.headers("carol", 1, csrf=True))
        self.assertEqual(denied.status_code, 404)
        bob = await self.client.get("/api/devices", headers=self.headers("bob", 1))
        self.assertEqual(bob.json()["count"], 1)

    async def test_registration_rejects_csrf_and_header_mismatch(self):
        missing_csrf = await self.client.post("/api/devices/register",
            headers=self.headers("alice", 1),
            json={"device_id": device(1), "platform": "ios"})
        self.assertEqual(missing_csrf.status_code, 403)
        mismatched = await self.client.post("/api/devices/register",
            headers=self.headers("alice", 1, csrf=True),
            json={"device_id": device(2), "platform": "ios"})
        self.assertEqual(mismatched.status_code, 400)

    async def test_legacy_clients_remain_compatible_during_rollout(self):
        # The migration intentionally does not enforce device headers for
        # older builds and web; this is a compatibility mode, not attestation.
        old_client = await self.client.get("/api/music",
            headers={"x-test-account": "alice"})
        self.assertEqual(old_client.status_code, 200)


if __name__ == "__main__":
    unittest.main()
