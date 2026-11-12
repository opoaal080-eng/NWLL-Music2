"""Checks that only SoundCloud-specific clients get Happ routing."""
import os
import unittest
from unittest.mock import patch

from soundcloud_proxy import (
    DEFAULT_SC_PROXY, direct_async_client, soundcloud_async_client,
    soundcloud_client, soundcloud_proxy_url, soundcloud_ytdlp_options,
)


class SoundCloudProxyTests(unittest.TestCase):
    def test_default_happ_proxy(self):
        with patch.dict(os.environ, {"NW_SC_PROXY": DEFAULT_SC_PROXY}):
            self.assertEqual(soundcloud_proxy_url(), "http://127.0.0.1:10809")
            with patch("soundcloud_proxy.httpx.AsyncClient") as factory:
                soundcloud_async_client(timeout=7)
                factory.assert_called_once_with(
                    proxy=DEFAULT_SC_PROXY, trust_env=False, timeout=7)
            with patch("soundcloud_proxy.httpx.Client") as factory:
                soundcloud_client(timeout=5)
                factory.assert_called_once_with(
                    proxy=DEFAULT_SC_PROXY, trust_env=False, timeout=5)

    def test_legacy_server_proxy_variable_has_priority(self):
        with patch.dict(os.environ, {
            "NW_SC_PROXY": "http://127.0.0.1:10809",
            "NW_SC_PROXY_URL": "http://127.0.0.1:18080",
        }):
            self.assertEqual(soundcloud_proxy_url(), DEFAULT_SC_PROXY)

    def test_direct_client_never_receives_happ(self):
        with patch("soundcloud_proxy.httpx.AsyncClient") as factory:
            direct_async_client(timeout=6)
            factory.assert_called_once_with(trust_env=False, timeout=6)

    def test_no_global_proxy_or_leak_to_other_services(self):
        with patch.dict(os.environ, {"NW_SC_PROXY": DEFAULT_SC_PROXY,
                                     "HTTPS_PROXY": "http://untrusted.invalid:8080"}):
            with patch("soundcloud_proxy.httpx.AsyncClient") as factory:
                soundcloud_async_client()
                self.assertEqual(factory.call_args.kwargs["proxy"], DEFAULT_SC_PROXY)
                self.assertFalse(factory.call_args.kwargs["trust_env"])
                direct_async_client()
                self.assertNotIn("proxy", factory.call_args.kwargs)
                self.assertFalse(factory.call_args.kwargs["trust_env"])

    def test_reject_remote_or_unauthenticated_proxy(self):
        for invalid in (
            "", "http://evil.example:8080", "https://127.0.0.1:10809",
            "http://user:password@127.0.0.1:10809",
            "http://127.0.0.1:10809/proxy",
        ):
            with self.subTest(invalid=invalid):
                with patch.dict(os.environ, {"NW_SC_PROXY": invalid}):
                    with self.assertRaises(ValueError):
                        soundcloud_proxy_url()

    def test_per_invocation_ytdlp_options(self):
        opts = {"quiet": True}
        with patch.dict(os.environ, {"NW_SC_PROXY": DEFAULT_SC_PROXY}):
            routed = soundcloud_ytdlp_options(opts)
        self.assertEqual(routed, {"quiet": True, "proxy": DEFAULT_SC_PROXY})
        self.assertEqual(opts, {"quiet": True})


if __name__ == "__main__":
    unittest.main()
