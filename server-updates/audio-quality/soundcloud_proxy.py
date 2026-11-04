"""Per-source outbound transport for SoundCloud. Never changes system-wide proxy settings.

Nightwell's API, authentication, Caddy, webhooks and local ASGI calls must use
their own direct connections. Only explicitly created SoundCloud clients use Happ.
"""
import os
from urllib.parse import urlsplit

import httpx

DEFAULT_SC_PROXY = "http://127.0.0.1:10809"


def soundcloud_proxy_url():
    """Return a validated local Happ proxy. Fail closed when Happ is unavailable."""
    value = os.environ.get("NW_SC_PROXY_URL", DEFAULT_SC_PROXY).strip()
    if not value:
        raise ValueError("NW_SC_PROXY_URL cannot be empty")
    parts = urlsplit(value)
    if (parts.scheme != "http" or parts.hostname not in
            ("127.0.0.1", "localhost", "::1") or not parts.port or
            parts.username is not None or parts.password is not None or
            parts.path not in ("", "/") or parts.query or parts.fragment):
        raise ValueError("NW_SC_PROXY_URL must point to a local HTTP proxy, e.g. http://127.0.0.1:10809")
    return value


def soundcloud_async_client(**kwargs):
    """httpx: use only for SoundCloud's API, OAuth and media requests."""
    if "proxy" in kwargs or "trust_env" in kwargs:
        raise TypeError("Proxy routing is managed by soundcloud_async_client")
    kwargs.setdefault("timeout", 8.0)
    return httpx.AsyncClient(proxy=soundcloud_proxy_url(), trust_env=False, **kwargs)


def soundcloud_client(**kwargs):
    """Synchronous httpx client for SoundCloud outbound fetches."""
    if "proxy" in kwargs or "trust_env" in kwargs:
        raise TypeError("Proxy routing is managed by soundcloud_client")
    kwargs.setdefault("timeout", 8.0)
    return httpx.Client(proxy=soundcloud_proxy_url(), trust_env=False, **kwargs)


def soundcloud_requests_session():
    """requests Session for SoundCloud only; never use this for Nightwell API."""
    import requests

    proxy = soundcloud_proxy_url()
    client = requests.Session()
    client.trust_env = False
    client.proxies.update({"http": proxy, "https": proxy})
    return client


def soundcloud_ytdlp_options(options=None):
    """Per-invocation yt-dlp options, not a global environment proxy."""
    merged = dict(options or {})
    merged["proxy"] = soundcloud_proxy_url()
    return merged


def direct_async_client(**kwargs):
    """Explicit direct outbound httpx client for other services."""
    if "proxy" in kwargs or "trust_env" in kwargs:
        raise TypeError("Direct client does not accept proxy overrides")
    return httpx.AsyncClient(trust_env=False, **kwargs)
