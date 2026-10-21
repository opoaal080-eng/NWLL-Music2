#!/usr/bin/env python3
"""Static file checks, do not claim a completed native build."""
import argparse, pathlib, xml.etree.ElementTree as ET, sys
root=pathlib.Path(__file__).resolve().parents[1]
ap=argparse.ArgumentParser();ap.add_argument('--android',action='store_true');ap.add_argument('--windows',action='store_true');args=ap.parse_args()
if not args.android and not args.windows:args.android=args.windows=True
issues=[];count=0
for name,enabled,patterns in [('Android',args.android,['android/app/src/**/*.xml']),('Windows',args.windows,['windows/*.xaml'])]:
 if not enabled: continue
 paths=[p for pat in patterns for p in root.glob(pat)]
 if not paths:issues.append(f'{name}: missing XML/XAML files')
 for p in paths:
  count+=1
  try:ET.parse(p)
  except ET.ParseError as e:issues.append(f'{p.relative_to(root)}: {e}')
for path in ['android/app/build.gradle','android/settings.gradle'] if args.android else []:
 if not (root/path).is_file():issues.append('Missing '+path)
for path in ['windows/Nightwell.Native.csproj'] if args.windows else []:
 if not (root/path).is_file():issues.append('Missing '+path)
for issue in issues:print('FAIL:',issue,file=sys.stderr)
print(f'Validated {count} XML/XAML files. Errors: {len(issues)}')
sys.exit(bool(issues))
