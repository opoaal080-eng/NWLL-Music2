#!/usr/bin/env python3
"""Generate a provenance manifest for an actual CI build; refuse to call absent artifacts successful."""
import argparse, hashlib, json, pathlib, os, datetime
p=argparse.ArgumentParser()
p.add_argument('--platform', choices=['android','ios','windows'],required=True)
p.add_argument('--directory',required=True)
p.add_argument('--output',default='build-provenance.json')
a=p.parse_args()
root=pathlib.Path(a.directory)
ext={'android':('.apk',),'ios':('.ipa',),'windows':('.exe',)}[a.platform]
files=[f for f in root.rglob('*') if f.is_file() and f.suffix.lower() in ext]
if not files: p.error('No build artifact found. Cannot report successful build.')
result={'platform':a.platform,'commit':os.environ.get('GITHUB_SHA','local-uncommitted'),'generated_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'artifacts':[{'path':str(f.relative_to(root)),'bytes':f.stat().st_size,'sha256':hashlib.sha256(f.read_bytes()).hexdigest()} for f in files]}
pathlib.Path(a.output).parent.mkdir(parents=True,exist_ok=True)
pathlib.Path(a.output).write_text(json.dumps(result,indent=2),encoding='utf-8')
print(json.dumps(result,indent=2))
