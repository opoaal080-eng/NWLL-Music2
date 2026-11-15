"""Integration boundaries: existing SPA routes and explicit custom coverage."""
import tempfile
import unittest
from pathlib import Path

import httpx
from fastapi import FastAPI
from starlette.responses import JSONResponse

from account_access import install


class RouteIntegrationTests(unittest.IsolatedAsyncioTestCase):
    def make_app(self, kind, prefixes=None):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        app = FastAPI()
        if kind == "catchall":
            @app.get("/{path:path}")
            async def fallback(path):
                return {"legacy_spa": path}
        elif kind == "mount":
            async def fallback(scope, receive, send):
                await JSONResponse({"legacy_spa": True})(scope, receive, send)
            app.mount("/", fallback)
        else:
            @app.get("/download/track")
            async def download():
                return {"ok": True}
        options = {} if prefixes is None else {"protected_prefixes": prefixes}
        install(app, lambda request: request.headers.get("x-test-user"),
                Path(temporary.name) / "access.db",
                lambda account: {"premium": False, "expires_at": None},
                lambda request: request.headers.get("x-csrf-token") == "csrf",
                lambda request: request.headers.get("x-test-session"), **options)
        return app

    async def check_fallback(self, kind):
        app = self.make_app(kind)
        headers = {"x-test-user": "alice", "x-test-session": "session-1"}
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="https://music.nightwell.fun") as client:
            response = await client.get("/api/family", headers=headers)
            self.assertEqual(response.status_code, 200)
            self.assertIn("family", response.json())
            access = await client.get("/api/account/access", headers=headers)
            self.assertEqual(access.json()["device_limit"], 2)
            page = await client.get("/family")
            self.assertIn("text/html", page.headers["content-type"])
            self.assertIn("Семейный Premium", page.text)
            old = await client.get("/legacy-page")
            self.assertIn("legacy_spa", old.json())

    async def test_spa_catchall_does_not_swallow_module_routes(self):
        await self.check_fallback("catchall")

    async def test_root_mount_does_not_swallow_module_routes(self):
        await self.check_fallback("mount")

    async def test_configured_download_path_enforces_device_token(self):
        app = self.make_app("download", ("/api/", "/download/"))
        headers = {"x-test-user": "alice", "x-test-session": "session-1", "x-csrf-token": "csrf"}
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="https://music.nightwell.fun") as client:
            denied = await client.get("/download/track", headers=headers)
            self.assertEqual(denied.status_code, 401)
            registered = await client.post("/api/devices/register", headers=headers,
                                           json={"name": "Phone", "platform": "ios"})
            self.assertEqual(registered.status_code, 200)
            headers["x-nw-device-token"] = registered.json()["device_token"]
            allowed = await client.get("/download/track", headers=headers)
            self.assertEqual(allowed.status_code, 200)


if __name__ == "__main__":
    unittest.main()
