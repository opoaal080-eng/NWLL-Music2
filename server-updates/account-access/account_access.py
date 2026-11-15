"""FastAPI integration: account devices and three-person Premium sharing.

The host supplies verified identity, a stable authenticated session key, CSRF,
and a synchronous DIRECT billing snapshot. No checkout, price or invoice is
created here. See account_access_host.example.py for explicit host wiring.
"""
import inspect
import json
import math
import secrets
import sqlite3
import time
from pathlib import Path
from urllib.parse import urlsplit

from fastapi import HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse
from starlette.concurrency import run_in_threadpool as _run_in_threadpool
from starlette.middleware.base import BaseHTTPMiddleware

from access_database import AccessDatabase, AccessError
from device_access import DeviceService
from family_access import FamilyService

MAX_BODY = 16384
DEVICE_COOKIE = "nw_device_token"
AUTH_PATHS = frozenset({"/api/login", "/api/register", "/api/logout"})
RECOVERY_PATHS = frozenset({
    "/api/me", "/api/premium/me", "/api/account/access",
    "/api/premium/lava/checkout", "/api/premium/lava/verify",
    "/api/premium/lava/renewal", "/api/premium/lava/cancel-renewal",
})
PRIVATE_PREFIXES = ("/api/", "/stream/", "/audio/", "/media/")


async def run_in_threadpool(function, *args, **kwargs):
    try:
        return await _run_in_threadpool(function, *args, **kwargs)
    except sqlite3.Error as exc:
        raise AccessError(503, "access_unavailable", "Хранилище доступа временно недоступно.") from exc


def failure(error):
    return JSONResponse(status_code=error.status_code,
                        content={"error": error.message, "detail": error.message, "code": error.code},
                        headers={"Cache-Control": "no-store"})


async def invoke(function, *args):
    if inspect.iscoroutinefunction(function):
        return await function(*args)
    result = await run_in_threadpool(function, *args)
    return await result if inspect.isawaitable(result) else result


async def body_object(request):
    chunks, length = [], 0
    async for chunk in request.stream():
        length += len(chunk)
        if length > MAX_BODY:
            raise AccessError(413, "body_too_large", "Слишком большой запрос.")
        chunks.append(chunk)
    try:
        body = json.loads(b"".join(chunks))
    except (ValueError, UnicodeDecodeError):
        raise AccessError(400, "invalid_json", "Некорректный JSON.")
    if not isinstance(body, dict):
        raise AccessError(400, "invalid_json", "Ожидается объект JSON.")
    return body


class AccessController:
    def __init__(self, *, identity, database_path, direct_premium, csrf_verifier,
                 session_key, public_origin, enforce=True, clock=time.time,
                 protected_prefixes=PRIVATE_PREFIXES):
        if not all(callable(value) for value in (identity, direct_premium, csrf_verifier, session_key)):
            raise ValueError("Configure trusted identity, direct_premium, csrf_verifier and session_key callbacks")
        if inspect.iscoroutinefunction(direct_premium) or inspect.iscoroutinefunction(session_key):
            raise ValueError("direct_premium and session_key must be synchronous host callbacks")
        origin = urlsplit(public_origin)
        if (origin.scheme != "https" or not origin.hostname or origin.username or origin.password or
                origin.path not in ("", "/") or origin.query or origin.fragment):
            raise ValueError("public_origin must be an HTTPS origin without a path, query or credentials")
        self.public_origin = public_origin.rstrip("/")
        self.identity = identity
        self.direct_premium = direct_premium
        self.csrf_verifier = csrf_verifier
        self.session_key = session_key
        self.enforce = bool(enforce)
        if (not isinstance(protected_prefixes, (tuple, list)) or not protected_prefixes or
                any(not isinstance(prefix, str) or not prefix.startswith("/") for prefix in protected_prefixes)):
            raise ValueError("Configure non-empty protected URL prefixes")
        self.protected_prefixes = tuple(protected_prefixes)
        self.clock = clock
        self.database = AccessDatabase(database_path)
        self.devices = DeviceService(self.database, clock=clock)
        self.families = FamilyService(self.database, clock=clock)

    def _direct(self, account_id):
        try:
            result = self.direct_premium(account_id)
            if inspect.isawaitable(result):
                if inspect.iscoroutine(result):
                    result.close()
                raise TypeError("direct_premium must be synchronous")
            if not isinstance(result, dict) or type(result.get("premium")) is not bool:
                raise ValueError("Invalid direct premium snapshot")
            expires = result.get("expires_at")
            if expires is not None and (type(expires) not in (int, float) or not math.isfinite(expires)):
                raise ValueError("expires_at must be an epoch timestamp or None")
            active = result["premium"] and (expires is None or expires > self.clock())
            return {"premium": active, "expires_at": expires if active else None}
        except AccessError:
            raise
        except Exception as exc:
            raise AccessError(503, "premium_unavailable", "Не удалось проверить подписку. Попробуйте позже.") from exc

    def _direct_active(self, account_id):
        return self._direct(account_id)["premium"]

    def access_for(self, account_id):
        """Synchronous, authoritative snapshot; safe to use in host paid guards."""
        direct = self._direct(account_id)
        if direct["premium"]:
            return {"premium": True, "source": "direct", "expires_at": direct["expires_at"],
                    "device_limit": 5, "billing_owner": True}
        owner = self.families.owner_for(account_id)
        if owner is not None and owner != account_id:
            paid = self._direct(owner)
            # Membership may have changed while the billing adapter ran.
            if paid["premium"] and self.families.owner_for(account_id) == owner:
                return {"premium": True, "source": "family", "expires_at": paid["expires_at"],
                        "device_limit": 5, "billing_owner": False, "family_owner_id": owner}
        return {"premium": False, "source": "free", "expires_at": None,
                "device_limit": 2, "billing_owner": False}

    def require_premium(self, account_id):
        result = self.access_for(str(account_id))
        if not result["premium"]:
            raise AccessError(402, "premium_required", "Нужна действующая подписка Premium.")
        return result

    def authorize_device(self, account_id, session_key, device_token):
        """Explicit guard for other private routes and authenticated WebSockets.

        A WebSocket host must call this on connect and before protected messages;
        HTTP middleware cannot revoke an already-established socket by itself.
        """
        account_id = str(account_id)
        return self.devices.authorize(account_id, session_key, device_token,
                                      lambda: self.access_for(account_id)["device_limit"])

    def premium_response(self, account_id, original):
        """Augment the account's own response; never borrow the owner's invoices."""
        if not isinstance(original, dict):
            raise TypeError("The host premium response must be a dictionary")
        access = self.access_for(str(account_id))
        response = dict(original)
        response.update(premium=access["premium"], expires_at=access["expires_at"],
                        subscription_source=access["source"], billing_owner=access["billing_owner"],
                        device_limit=access["device_limit"])
        return response

    async def account(self, request, *, required=True):
        if hasattr(request.state, "nw_access_account"):
            value = request.state.nw_access_account
            if value is None and required:
                raise AccessError(401, "authentication_required", "Войдите в аккаунт.")
            return value
        try:
            value = await invoke(self.identity, request)
        except HTTPException as exc:
            if exc.status_code in (401, 403):
                value = None
            else:
                raise AccessError(503, "identity_unavailable", "Не удалось проверить аккаунт.") from exc
        except Exception as exc:
            raise AccessError(503, "identity_unavailable", "Не удалось проверить аккаунт.") from exc
        if isinstance(value, dict):
            value = value.get("user_id", value.get("id"))
        if value is not None:
            if not isinstance(value, (str, int)) or isinstance(value, bool):
                raise AccessError(503, "identity_unavailable", "Сервер вернул некорректный аккаунт.")
            value = str(value)
            if not value or len(value) > 256 or "\0" in value:
                value = None
        request.state.nw_access_account = value
        if value is None and required:
            raise AccessError(401, "authentication_required", "Войдите в аккаунт.")
        return value

    async def context(self, request, *, mutate=False):
        account = await self.account(request)
        try:
            key = await run_in_threadpool(self.session_key, request)
            if inspect.isawaitable(key):
                if inspect.iscoroutine(key):
                    key.close()
                raise TypeError("session_key must be synchronous")
        except Exception as exc:
            raise AccessError(503, "session_adapter_required", "Не удалось определить сессию.") from exc
        await run_in_threadpool(self.devices.check_session, account, key)
        if mutate:
            origin = request.headers.get("origin")
            if origin and origin.rstrip("/") != self.public_origin:
                raise AccessError(403, "invalid_origin", "Запрос с другого сайта запрещён.")
            try:
                valid = await invoke(self.csrf_verifier, request)
            except Exception as exc:
                raise AccessError(403, "csrf_required", "Не подтверждена защита сессии.") from exc
            if valid is not True:
                raise AccessError(403, "csrf_required", "Не подтверждена защита сессии.")
        return account, key

    def family_state(self, account):
        family = self.families.family_for(account)
        if family is not None:
            family["active"] = self._direct_active(family["owner_id"])
        return {"family": family, "access": self.access_for(account)}


class AccountAccessMiddleware(BaseHTTPMiddleware):
    def __init__(self, app, controller):
        super().__init__(app)
        self.controller = controller

    async def dispatch(self, request, call_next):
        controller, path = self.controller, request.url.path
        if not path.startswith(controller.protected_prefixes) or path in AUTH_PATHS or path == "/family":
            return await call_next(request)
        try:
            account = await controller.account(request, required=False)
            if account is None:
                return await call_next(request)
            account, key = await controller.context(request)
            recovery = path in RECOVERY_PATHS or path == "/api/devices" or path.startswith("/api/devices/") or path == "/api/family" or path.startswith("/api/family/")
            if controller.enforce and not recovery:
                token = request.headers.get("x-nw-device-token") or request.cookies.get(DEVICE_COOKIE)
                await run_in_threadpool(controller.authorize_device, account, key, token)
        except AccessError as exc:
            return failure(exc)
        except sqlite3.Error:
            return failure(AccessError(503, "access_unavailable", "Не удалось проверить доступ. Попробуйте позже."))
        return await call_next(request)


def install(app, identity, database_path, direct_premium, csrf_verifier, session_key,
            public_origin="https://music.nightwell.fun", enforce=True, clock=time.time,
            protected_prefixes=PRIVATE_PREFIXES):
    if getattr(app.state, "nightwell_account_access", None) is not None:
        raise RuntimeError("Account access is already installed")
    for route in app.routes:
        path = getattr(route, "path", "")
        if path == "/family" or path == "/api/account/access" or path.startswith(("/api/devices", "/api/family")):
            raise RuntimeError("Existing device/family routes must be reviewed before installing account access")
    original_route_count = len(app.router.routes)
    controller = AccessController(identity=identity, database_path=database_path,
        direct_premium=direct_premium, csrf_verifier=csrf_verifier, session_key=session_key,
        public_origin=public_origin, enforce=enforce, clock=clock,
        protected_prefixes=protected_prefixes)
    app.state.nightwell_account_access = controller

    @app.exception_handler(AccessError)
    async def access_error_handler(request, error):
        return failure(error)

    @app.get("/api/account/access")
    async def account_access(request: Request):
        account, _ = await controller.context(request)
        return JSONResponse(await run_in_threadpool(controller.access_for, account), headers={"Cache-Control": "no-store"})

    @app.get("/api/devices")
    async def devices(request: Request):
        account, key = await controller.context(request)
        access = await run_in_threadpool(controller.access_for, account)
        result = await run_in_threadpool(controller.devices.list_devices, account, key, access["device_limit"])
        result["premium"] = access["premium"]
        return JSONResponse(result, headers={"Cache-Control": "no-store"})

    @app.post("/api/devices/register")
    async def register(request: Request):
        account, key = await controller.context(request, mutate=True)
        body = await body_object(request)
        token = body.get("device_token") or request.headers.get("x-nw-device-token")
        if token is None:
            cookie = request.cookies.get(DEVICE_COOKIE)
            # The browser can switch Nightwell accounts. A credential belonging
            # to the previous account is not evidence for the new account, nor
            # should it prevent a fresh, quota-checked registration.
            if cookie and await run_in_threadpool(controller.devices.knows_credential, account, cookie):
                token = cookie
        result = await run_in_threadpool(controller.devices.register, account, key,
            platform=body.get("platform"), name=body.get("name"),
            device_id=body.get("device_id"), device_token=token,
            limit_provider=lambda: controller.access_for(account)["device_limit"])
        response = JSONResponse(result, headers={"Cache-Control": "no-store"})
        if body.get("platform") == "web":
            response.set_cookie(DEVICE_COOKIE, result["device_token"], httponly=True, secure=True,
                                samesite="lax", max_age=365*86400, path="/")
        return response

    @app.delete("/api/devices/{device_id}")
    async def remove_device(device_id: str, request: Request):
        account, _ = await controller.context(request, mutate=True)
        result = await run_in_threadpool(controller.devices.remove, account, device_id)
        return JSONResponse(result, headers={"Cache-Control": "no-store"})

    @app.get("/api/family")
    async def family(request: Request):
        account, _ = await controller.context(request)
        return JSONResponse(await run_in_threadpool(controller.family_state, account), headers={"Cache-Control": "no-store"})

    @app.post("/api/family/invitations")
    async def create_invite(request: Request):
        account, _ = await controller.context(request, mutate=True)
        result = await run_in_threadpool(controller.families.create_invite, account, allow_owner=controller._direct_active)
        result["invite_url"] = controller.public_origin + "/family#invite=" + result["token"]
        return JSONResponse(result, headers={"Cache-Control": "no-store", "Referrer-Policy": "no-referrer"})

    @app.post("/api/family/invitations/preview")
    async def preview_invite(request: Request):
        body = await body_object(request)
        preview = await run_in_threadpool(controller.families.preview, body.get("token"))
        active = await run_in_threadpool(controller._direct_active, preview["owner_id"])
        return JSONResponse({"available": preview["available"] and active,
            "reason": preview["reason"] if preview["reason"] else (None if active else "owner_subscription_inactive"),
            "expires_at": preview["expires_at"], "capacity": 3}, headers={"Cache-Control": "no-store"})

    @app.post("/api/family/invitations/accept")
    async def accept_invite(request: Request):
        account, _ = await controller.context(request, mutate=True)
        body = await body_object(request)
        result = await run_in_threadpool(controller.families.accept, account, body.get("token"), allow_owner=controller._direct_active)
        return JSONResponse({"family": result, "access": await run_in_threadpool(controller.access_for, account)},
                            headers={"Cache-Control": "no-store"})

    @app.delete("/api/family/invitations/{invite_id}")
    async def revoke_invite(invite_id: str, request: Request):
        account, _ = await controller.context(request, mutate=True)
        return await run_in_threadpool(controller.families.revoke_invite, account, invite_id)

    @app.delete("/api/family/members/{member_id}")
    async def remove_member(member_id: str, request: Request):
        account, _ = await controller.context(request, mutate=True)
        return await run_in_threadpool(controller.families.remove_member, account, member_id)

    @app.post("/api/family/leave")
    async def leave(request: Request):
        account, _ = await controller.context(request, mutate=True)
        return await run_in_threadpool(controller.families.leave, account)

    @app.delete("/api/family")
    async def dissolve(request: Request):
        account, _ = await controller.context(request, mutate=True)
        return await run_in_threadpool(controller.families.dissolve, account)

    @app.get("/family", response_class=HTMLResponse, include_in_schema=False)
    async def family_page():
        nonce = secrets.token_urlsafe(24)
        html = Path(__file__).with_name("family_page.html").read_text(encoding="utf-8")
        return HTMLResponse(html.replace("__NW_CSP_NONCE__", nonce), headers={
            "Cache-Control": "no-store", "Referrer-Policy": "no-referrer",
            "X-Content-Type-Options": "nosniff",
            "Content-Security-Policy": "default-src 'none'; script-src 'nonce-" + nonce + "'; style-src 'nonce-" + nonce + "'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'",
        })

    # Preserve old route order while ensuring a pre-existing SPA catch-all or
    # Mount('/') cannot swallow the newly installed, explicitly scoped routes.
    module_routes = app.router.routes[original_route_count:]
    app.router.routes[:] = module_routes + app.router.routes[:original_route_count]
    app.openapi_schema = None
    app.add_middleware(AccountAccessMiddleware, controller=controller)
    return controller
