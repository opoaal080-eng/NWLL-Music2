#!/usr/bin/env python3
"""Generate the monochrome Nightwell iOS icon with Python stdlib only."""
from pathlib import Path
import math
import struct
import zlib

SIZE = 192
def distance(x, y, a, b, c, d):
    dx, dy = c - a, d - b
    t = max(0.0, min(1.0, ((x-a)*dx + (y-b)*dy)/(dx*dx + dy*dy)))
    return math.hypot(x-a-t*dx, y-b-t*dy)

def chunk(name, data):
    return struct.pack(">I", len(data)) + name + data + struct.pack(">I", zlib.crc32(name+data) & 0xffffffff)

for folder, SIZE in [('mipmap-mdpi',48),('mipmap-hdpi',72),('mipmap-xhdpi',96),('mipmap-xxhdpi',144),('mipmap-xxxhdpi',192)]:
    rows = []
    for iy in range(SIZE):
        y = (iy+0.5)/SIZE
        row = bytearray([0])
        for ix in range(SIZE):
            x = (ix+0.5)/SIZE
            base = round(8 + 9*(1-math.hypot(x-.5,y-.46)/.8))
            segments = ((.325,.72,.325,.29),(.325,.29,.675,.72),(.675,.72,.675,.29))
            dist = min(distance(x,y,*segment) for segment in segments)
            solid = max(0.0,min(1.0,(.044-dist)*SIZE/1.4))
            glow = .14*math.exp(-(dist/.053)**2)
            haze = .05*math.exp(-((y-.76)/.07)**2-((x-.5)/.32)**2)
            factor = max(0.0,min(1.0,solid*.93+glow+haze))
            tone = int(max(0,min(255,base+(248-base)*factor)))
            row.extend((tone,tone,tone,255))
        rows.append(row)
    raw = b"".join(rows)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR",struct.pack(">IIBBBBB",SIZE,SIZE,8,6,0,0,0)) + chunk(b"IDAT",zlib.compress(raw,9)) + chunk(b"IEND",b"")
    target = Path(__file__).resolve().parent / 'app/src/main/res' / folder / 'ic_launcher.png'
    target.parent.mkdir(parents=True,exist_ok=True)
    target.write_bytes(png)
    print('Generated monochrome Android icon',target)
