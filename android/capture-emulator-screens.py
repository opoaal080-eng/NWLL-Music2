#!/usr/bin/env python3
"""Capture screenshots from the actual debug APK in an Android emulator.

The debug-only nativeSmoke fixture supplies deterministic placeholder tracks,
so CI never needs a personal account or network access to the music API.
"""
import html
import json
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
]


def adb(*args, timeout=45, check=True):
    return subprocess.run(
        ["adb", *args], capture_output=True, timeout=timeout, check=check
    )


def launch(screen):
    adb("shell", "am", "force-stop", PACKAGE)
    command = adb(
        "shell", "am", "start", "-W", "-n", ACTIVITY,
        "--ez", "nativeSmoke", "true", "--es", "screen", screen,
    )
    if b"Error" in command.stdout or b"Exception" in command.stdout:
        raise RuntimeError(command.stdout.decode(errors="replace"))
    time.sleep(1.5)


def capture(name):
    image = adb("exec-out", "screencap", "-p", timeout=30).stdout
    if not image.startswith(b"\x89PNG\r\n\x1a\n") or len(image) < 4096:
        raise RuntimeError(f"Invalid or empty screenshot for {name}")
    (OUT / (name + ".png")).write_bytes(image)
    # Save the accessibility hierarchy beside the screenshot for UI debugging.
    for attempt in range(3):
        dump = adb("shell", "uiautomator", "dump",
                   "/sdcard/nightwell-window.xml", check=False, timeout=35)
        if dump.returncode == 0:
            xml = adb("exec-out", "cat", "/sdcard/nightwell-window.xml",
                      check=False).stdout
            try:
                root = ET.fromstring(xml)
                if any(node.get("package") == PACKAGE
                       for node in root.iter("node")):
                    (OUT / (name + ".xml")).write_bytes(xml)
                    return
            except ET.ParseError:
                pass
        time.sleep(1)
    raise RuntimeError(f"Could not verify Nightwell UI hierarchy for {name}")


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
        time.sleep(2)
        for name, page in [("16-landscape-home", "Главная"),
                           ("17-landscape-library", "Медиатека"),
                           ("18-landscape-player", "player")]:
            print(f"Capturing {name}: {page}", flush=True)
            launch(page)
            capture(name)
            records.append({"file": name + ".png", "screen": page,
                            "orientation": "landscape"})
    finally:
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
