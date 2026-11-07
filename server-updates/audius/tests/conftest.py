import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
for directory in (ROOT, ROOT.parent / 'adaptive-wave', ROOT.parent / 'playlist-transfer'):
    sys.path.insert(0, str(directory))
