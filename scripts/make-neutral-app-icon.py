#!/usr/bin/env python3
"""Generate neutral monochrome Nightwell app icons without third-party packages.
The compiled asset catalog, not legacy IPA resources, is the single source of truth.
"""
import argparse
import math
import shutil
import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def segment_distance(x, y, ax, ay, bx, by):
    dx, dy = bx-ax, by-ay
    t = max(0.0, min(1.0, ((x-ax)*dx+(y-ay)*dy)/(dx*dx+dy*dy)))
    return math.hypot(x-ax-t*dx, y-ay-t*dy)

def render(size):
    raw = bytearray()
    for j in range(size):
        raw.append(0)
        y = (j+0.5)/size
        for i in range(size):
            x = (i+0.5)/size
            # Subtle neutral spotlight, not a colored or seasonal theme.
            halo = max(0., 1. - math.hypot(x-.48, y-.39)/.72)
            base = int(10 + 15*halo*halo)
            ring = abs(math.hypot((x-.5)/.42,(y-.5)/.42)-1)
            border = max(0., min(1., (.016-ring)/.012)) * .075
            d = min(segment_distance(x,y,.315,.70,.315,.30),
                    segment_distance(x,y,.315,.30,.685,.70),
                    segment_distance(x,y,.685,.70,.685,.30))
            coverage = max(0., min(1., (.052-d)*size/2.5))
            v = int(max(0,min(255,base+(230-base)*coverage + border*170)))
            raw.extend((v,v,v))
    def chunk(tag,payload):
        return struct.pack(">I",len(payload))+tag+payload+struct.pack(">I",zlib.crc32(tag+payload)&0xffffffff)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR",struct.pack(">2I5B",size,size,8,2,0,0,0)) + chunk(b"IDAT",zlib.compress(raw,6)) + chunk(b"IEND",b"")

def write(path,size):
    path.parent.mkdir(parents=True,exist_ok=True)
    data=render(size)
    path.write_bytes(data)
    print(f"Neutral Nightwell icon: {path.relative_to(ROOT)} ({len(data)} bytes)")

parser=argparse.ArgumentParser()
parser.add_argument("--platform",choices=["ios","android","all"],default="all")
args=parser.parse_args()
if args.platform in ("ios","all"):
    main = ROOT/"NightwellMusic/Assets.xcassets/AppIcon.appiconset/Icon.png"
    write(main,1024)
    mirror=ROOT/"source/NightwellMusic/Assets.xcassets/AppIcon.appiconset/Icon.png"
    mirror.parent.mkdir(parents=True,exist_ok=True)
    shutil.copyfile(main,mirror)
if args.platform in ("android","all"):
    for folder,dimension in (("mdpi",48),("hdpi",72),("xhdpi",96),("xxhdpi",144),("xxxhdpi",192)):
        write(ROOT/f"android/app/src/main/res/mipmap-{folder}/ic_launcher.png",dimension)
