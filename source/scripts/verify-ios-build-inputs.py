#!/usr/bin/env python3
"""Ensure iOS build inputs are complete before XcodeGen and Xcode run."""
from pathlib import Path
import json, plistlib, subprocess, sys
root=Path(__file__).resolve().parents[1]
required=['project.yml','NightwellMusic/App.swift','NightwellMusic/NightwellMusic.entitlements','NightwellMusic/Assets.xcassets/AppIcon.appiconset/Contents.json','scripts/build-provenance.py']
missing=[p for p in required if not (root/p).is_file()]
if missing: raise SystemExit('Missing files: '+', '.join(missing))
plistlib.loads((root/'NightwellMusic/NightwellMusic.entitlements').read_bytes())
for p in (root/'NightwellMusic/Assets.xcassets').rglob('Contents.json'):
    data=json.loads(p.read_text(encoding='utf-8'))
    for item in data.get('images',[]):
        if 'filename' in item and not (p.parent/item['filename']).is_file():
            raise SystemExit(f'Missing resource: {p.parent/item["filename"]}')
print('iOS project inputs OK; this does not mean the app has compiled successfully.')
