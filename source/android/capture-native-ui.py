from pathlib import Path
import subprocess
import time
import xml.etree.ElementTree as ET

out = Path("android/native-smoke")
out.mkdir(parents=True, exist_ok=True)

def adb(*args, check=True):
    return subprocess.run(["adb", *args], check=check, capture_output=True, text=True, timeout=40)

def capture():
    adb("shell", "screencap", "-p", "/sdcard/native-home.png", check=False)
    adb("pull", "/sdcard/native-home.png", str(out / "home.png"), check=False)

# Cold-start AOSP emulator UI automation often reports an empty accessibility
# root until the launcher finishes booting. Wait and re-open the actual app.
last_error = ""
for attempt in range(15):
    if attempt in (0, 4, 9):
        adb("shell", "input", "keyevent", "82", check=False)
        adb("shell", "am", "start", "-W", "-n", "fun.nightwell.music/.MainActivity", "--ez", "nativeSmoke", "true", "--es", "screen", "Главная", check=False)
    adb("shell", "rm", "-f", "/sdcard/native-window.xml", check=False)
    dump = adb("shell", "uiautomator", "dump", "/sdcard/native-window.xml", check=False)
    pulled = adb("pull", "/sdcard/native-window.xml", str(out / "window.xml"), check=False)
    if pulled.returncode == 0:
        try:
            root = ET.parse(out / "window.xml").getroot()
            nodes = list(root.iter("node"))
            if nodes:
                capture()
                print(f"Accessibility hierarchy captured on attempt {attempt + 1}")
                break
        except (ET.ParseError, OSError) as exc:
            last_error = str(exc)
    last_error = (dump.stderr or dump.stdout or pulled.stderr or last_error).strip()[-600:]
    time.sleep(3)
else:
    capture()
    log = adb("logcat", "-d", "-s", "AndroidRuntime:E", check=False)
    (out / "errors.txt").write_text(log.stdout or "", encoding="utf-8")
    raise RuntimeError(f"Emulator returned no accessibility hierarchy after 15 attempts: {last_error}")
