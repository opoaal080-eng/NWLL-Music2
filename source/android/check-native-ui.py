from pathlib import Path
import subprocess
import time
import xml.etree.ElementTree as ET

# Some hosted AOSP emulators display a launcher ANR during cold boot.
# Recover only this known system overlay; an app ANR or missing activity still fails.
for attempt in range(3):
    root=ET.fromstring(Path('android/native-smoke/window.xml').read_text())
    nodes=list(root.iter('node'))
    texts=[node.get('text','') for node in nodes]
    if any('Nightwell' in text for text in texts):break
    if attempt==2 or not any("Quickstep isn't responding" in text for text in texts):break
    subprocess.run(['adb','shell','am','force-stop','com.android.launcher3'],check=True)
    subprocess.run(['adb','shell','am','start','-W','-n','fun.nightwell.music/.MainActivity'],check=True)
    time.sleep(4)
    subprocess.run(['adb','shell','uiautomator','dump','/sdcard/native-window.xml'],check=True)
    subprocess.run(['adb','pull','/sdcard/native-window.xml','android/native-smoke/window.xml'],check=True)
    subprocess.run(['adb','shell','screencap','-p','/sdcard/native-home.png'],check=True)
    subprocess.run(['adb','pull','/sdcard/native-home.png','android/native-smoke/home.png'],check=True)
print(ET.tostring(root,encoding='unicode'))
assert not any('WebView' in node.get('class','') for node in nodes)
assert any('Nightwell' in node.get('text','') for node in nodes)
print('Native Android activity launched; UI hierarchy contains no WebView.')
