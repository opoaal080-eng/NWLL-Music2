#!/usr/bin/env python3
"""Run AFTER unsigned xcodebuild, BEFORE packaging Payload into an IPA.
This restores compiled resources from the older IPA build. It does not
restore editable image sources or the older executable's functionality.
"""
from pathlib import Path
import shutil, sys
base=Path(__file__).resolve().parent/'LegacyCompiledAssets'
app=Path(sys.argv[1]).resolve()
assert app.is_dir() and app.suffix=='.app', f'Invalid app bundle: {app}'
for name in ['Assets.car']:
    # Keep newly compiled app icon PNGs instead of restoring the old purple icon.
    assert (base/name).is_file(), f'Missing resource: {name}'
    shutil.copy2(base/name, app/name)
print('Restored original compiled graphics. Check runtime compatibility before distribution.')
