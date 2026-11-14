#!/usr/bin/env python3
"""Capture screenshots from the actual debug APK in an Android emulator.

The debug-only nativeSmoke fixture supplies deterministic placeholder tracks,
so CI never needs a personal account or network access to the music API.
"""
import html
import json
import struct
import subprocess
import time
import xml.etree.ElementTree as ET
from pathlib import Path

PACKAGE = "fun.nightwell.music"
ACTIVITY = PACKAGE + "/.MainActivity"
OUT = Path("android/native-smoke/screenshots")
SCREENS = [
    ("01-home", "Главная"),
    ("02-search", "Поиск"),
    ("03-library", "Медиатека"),
    ("04-favorites", "Избранное"),
    ("05-playlists", "Плейлисты"),
    ("06-offline", "Офлайн"),
    ("07-daily-playlists", "Подборки дня"),
    ("08-smart-playlists", "Умные плейлисты"),
    ("09-player", "player"),
    ("10-queue", "queue"),
    ("11-profile", "profile"),
    ("12-settings", "settings"),
    ("13-playback-settings", "settings-playback"),
    ("14-customization", "premium-appearance"),
    ("15-navigation-menu", "menu"),
    ("16-customization-settings", "settings-customization"),
    ("17-appearance-settings", "settings-appearance"),
    ("18-about", "settings-about"),
    ("19-equalizer", "premium-sound"),
    ("20-transfer", "transfer"),
    ("21-wave-settings", "wave-settings"),
    ("22-login", "auth"),
    ("23-track-menu", "track-menu"),
    ("24-track-menu-more", "track-menu-more"),
    ("25-player-menu", "player-menu"),
]


def adb(*args, timeout=45, check=True):
    return subprocess.run(
        ["adb", *args], capture_output=True, timeout=timeout, check=check
    )


def launch(screen):
    adb("shell", "am", "force-stop", PACKAGE, timeout=12)
    # Async launch avoids 'am start -W' hanging for 45 seconds on CI.
    command = adb(
        "shell", "am", "start", "-n", ACTIVITY,
        "--ez", "nativeSmoke", "true", "--es", "screen", screen,
        timeout=20,
    )
    if b"Error" in command.stdout or b"Exception" in command.stdout:
        raise RuntimeError(command.stdout.decode(errors="replace"))
    time.sleep(4)


def capture(name, landscape=False):
    # Android's launch splash can persist after the activity starts.
    # Retry sparse frames instead of publishing a blank white splash.
    image = b""
    for attempt in range(7):
        image = adb("exec-out", "screencap", "-p", timeout=25).stdout
        if image.startswith(b"\x89PNG\r\n\x1a\n") and len(image) >= 50000:
            break
        print(f"Waiting for {name} content (attempt {attempt + 1})", flush=True)
        time.sleep(2)
    if not image.startswith(b"\x89PNG\r\n\x1a\n") or len(image) < 50000:
        raise RuntimeError(f"App screen not ready for {name}; PNG bytes={len(image)}")
    width, height = struct.unpack(">II", image[16:24])
    if landscape and width <= height:
        raise RuntimeError(f"Landscape check {name} captured a portrait frame: {width}x{height}")
    if not landscape and width >= height:
        raise RuntimeError(f"Portrait check {name} captured a landscape frame: {width}x{height}")
    (OUT / (name + ".png")).write_bytes(image)
    # UIAutomator routinely wedges the GitHub headless Android emulator.
    # Validate screenshot PNG bytes and verify the rendered UI separately.
    try:
        state = adb("shell", "pidof", PACKAGE, timeout=6, check=False)
        if state.returncode != 0 or not state.stdout.strip():
            print(f"WARNING: {name}: target app PID missing", flush=True)
    except (subprocess.TimeoutExpired, OSError) as error:
        print(f"WARNING: {name}: PID check unavailable: {error}", flush=True)


def write_gallery(records):
    links = []
    for item in records:
        label = html.escape(item["screen"])
        filename = html.escape(item["file"], quote=True)
        links.append(
            f'<figure><a href="{filename}"><img src="{filename}" '
            f'alt="{label}"></a><figcaption>{label}</figcaption></figure>'
        )
    document = (
        '<!doctype html><html lang="ru"><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '<title>Nightwell Music - Android emulator screenshots</title>'
        '<style>body{background:#111;color:#fff;font:16px system-ui;'
        'padding:24px}main{display:grid;gap:24px;'
        'grid-template-columns:repeat(auto-fill,minmax(240px,1fr))}'
        'figure{margin:0}img{width:100%;border-radius:18px}'
        'figcaption{padding:8px}</style><h1>Nightwell Music / Android CI</h1>'
        '<p>Debug build, emulator, placeholder fixture data. '
        'Screenshots are not proof of authenticated server features.</p>'
        '<main>' + "".join(links) + '</main></html>'
    )
    (OUT / "index.html").write_text(document, encoding="utf-8")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    adb("shell", "settings", "put", "global", "window_animation_scale", "0")
    adb("shell", "settings", "put", "global", "transition_animation_scale", "0")
    adb("shell", "settings", "put", "global", "animator_duration_scale", "0")
    records = []
    try:
        for name, page in SCREENS:
            print(f"Capturing {name}: {page}", flush=True)
            launch(page)
            capture(name)
            records.append({"file": name + ".png", "screen": page,
                            "orientation": "portrait"})
        adb("shell", "settings", "put", "system", "accelerometer_rotation", "0")
        adb("shell", "settings", "put", "system", "user_rotation", "1")
        adb("shell", "cmd", "window", "set-user-rotation", "lock", "1", check=False)
        # A headless Pixel runner can ignore logical rotation commands. Try
        # emulator rotation, then report that limitation instead of claiming
        # portrait screenshots to be a landscape verification.
        adb("shell", "wm", "size", "2400x1080")
        time.sleep(2)
        probe = adb("exec-out", "screencap", "-p").stdout
        width, height = struct.unpack(">II", probe[16:24])
        if width <= height:
            adb("emu", "rotate", check=False)
            time.sleep(3)
            probe = adb("exec-out", "screencap", "-p").stdout
            width, height = struct.unpack(">II", probe[16:24])
        if width <= height:
            warning = (
                "Landscape screenshots unavailable on this headless emulator: "
                f"rotation remained {width}x{height}. The portrait screenshots "
                "were verified; landscape layouts were NOT tested.\\n"
            )
            print("WARNING: " + warning, flush=True)
            (OUT / "landscape-unavailable.txt").write_text(
                warning, encoding="utf-8"
            )
        else:
            for name, page in [("26-landscape-home", "Главная"),
                               ("27-landscape-library", "Медиатека"),
                               ("28-landscape-player", "player")]:
                print(f"Capturing {name}: {page}", flush=True)
                launch(page)
                capture(name, landscape=True)
                records.append({"file": name + ".png", "screen": page,
                                "orientation": "landscape"})
    finally:
        adb("shell", "wm", "size", "reset", check=False)
        adb("shell", "cmd", "window", "set-user-rotation", "free", check=False)
        adb("shell", "settings", "put", "system", "user_rotation", "0",
            check=False)
        adb("shell", "settings", "put", "system", "accelerometer_rotation", "1",
            check=False)
    (OUT / "manifest.json").write_text(
        json.dumps({"app": PACKAGE, "fixture": "nativeSmoke",
                    "screenshots": records}, ensure_ascii=False, indent=2),
        encoding="utf-8")
    write_gallery(records)
    print(f"Saved {len(records)} emulator screenshots to {OUT}")


if __name__ == "__main__":
    main()
