#!/usr/bin/env python3
"""Run AFTER unsigned xcodebuild, BEFORE packaging Payload into an IPA.
This restores compiled resources from the older IPA build. It does not
restore editable image sources or the older executable's functionality.
"""
from pathlib import Path
import shutil, sys, subprocess, plistlib
base=Path(__file__).resolve().parent/'LegacyCompiledAssets'
app=Path(sys.argv[1]).resolve()
assert app.is_dir() and app.suffix=='.app', f'Invalid app bundle: {app}'
for name in ['Assets.car']:
    # Keep newly compiled app icon PNGs instead of restoring the old purple icon.
    assert (base/name).is_file(), f'Missing resource: {name}'
    shutil.copy2(base/name, app/name)
# iOS may use standalone app icon images even when the asset catalog is restored.
# Force those files to match the generated monochrome icon.
icon = Path(__file__).resolve().parent.parent/'NightwellMusic/Assets.xcassets/AppIcon.appiconset/Icon.png'
assert icon.is_file(), 'Missing generated icon'
for name, pixels in [('AppIcon60x60@2x.png',120), ('AppIcon76x76@2x~ipad.png',152)]:
    subprocess.run(['sips','-s','format','png','-z',str(pixels),str(pixels),str(icon),'--out',str(app/name)],check=True,stdout=subprocess.DEVNULL)
# Explicit icon filenames prevent the old compiled AppIcon rendition in Assets.car
# from overriding the new monochrome icon on iOS.
for name, pixels in [('NightwellMonoIcon.png', 120), ('NightwellMonoIcon@2x.png', 180)]:
    subprocess.run(['sips', '-s', 'format', 'png', '-z', str(pixels), str(pixels),
                    str(icon), '--out', str(app/name)], check=True, stdout=subprocess.DEVNULL)
info_path = app/'Info.plist'
with info_path.open('rb') as stream:
    info = plistlib.load(stream)
info.pop('CFBundleIcons', None)
info['CFBundleIcons'] = {'CFBundlePrimaryIcon': {
    'CFBundleIconFiles': ['NightwellMonoIcon', 'NightwellMonoIcon@2x'],
    'UIPrerenderedIcon': True
}}
info.pop('CFBundleIconName', None)
with info_path.open('wb') as stream:
    plistlib.dump(info, stream)
print('Restored compiled graphics and set an explicit monochrome app icon.')
