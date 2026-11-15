"""Copy, configure against the real server, then pass through --adapter.

This is a deliberately disabled template. Flipping the marker alone is not
sufficient: stable authenticated session identity and paid-route wiring are
required. Never put passwords, card data, or payment secrets in this file.
"""
import inspect
from fastapi import HTTPException

ADAPTER_CONFIGURED = False

# Required: return the stable server-side ID of the ALREADY AUTHENTICATED session.
# Do not use X-Session-ID, X-User-ID, device names or other client declarations.
# For example, this may read a session record already verified by identity().
SESSION_KEY = None

# Required: explicitly adapt every paid authorization guard and /api/premium/me
# in the REAL app. This callback receives (app, premium_service, controller).
# It must not change checkout, price, invoice ownership or personal billing data.
BIND_EXISTING_PREMIUM = None


def configure(*, app, identity, premium_service, csrf_verifier, module_install,
              database_path, public_origin, enforce):
    if ADAPTER_CONFIGURED is not True:
        raise RuntimeError("Настройте адаптер account-access перед запуском сервера.")
    if not callable(SESSION_KEY) or not callable(BIND_EXISTING_PREMIUM):
        raise RuntimeError("Настройте SESSION_KEY и BIND_EXISTING_PREMIUM по действующему app.py.")

    # Capture BEFORE any explicit rebinding of host authorization. Otherwise a
    # family entitlement might recursively sponsor another family.
    original_require = premium_service.require

    def direct_premium(account_id):
        try:
            result = original_require(str(account_id))
            if inspect.isawaitable(result):
                if inspect.iscoroutine(result):
                    result.close()
                raise RuntimeError("Нужен синхронный адаптер прямой подписки.")
        except HTTPException as error:
            if error.status_code in (402, 403):
                return {"premium": False, "expires_at": None}
            raise
        # None means the real expiry reader has NOT been wired here, not an
        # invented expiry date. Prefer the host's trusted actual expiry snapshot.
        return {"premium": True, "expires_at": None}

    controller = module_install(
        app, identity,
        database_path=database_path,
        direct_premium=direct_premium,
        csrf_verifier=csrf_verifier,
        session_key=SESSION_KEY,
        public_origin=public_origin,
        enforce=enforce,
    )
    result = BIND_EXISTING_PREMIUM(app, premium_service, controller)
    if inspect.isawaitable(result):
        if inspect.iscoroutine(result):
            result.close()
        raise RuntimeError("BIND_EXISTING_PREMIUM должен завершаться синхронно при запуске.")
    return controller
