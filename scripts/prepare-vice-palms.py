#!/usr/bin/env python3
"""Split the existing Vice sunset into a clean fixed sky and independent palm fronds.

Run during CI before packaging. Re-uses original bundled artwork, so no network
resources, video downloads or playback work are required at runtime.
"""
import argparse
import json
from pathlib import Path

import cv2
import numpy as np


def make_assets(source: Path, output: Path, platform: str):
    image = cv2.imread(str(source), cv2.IMREAD_COLOR)
    if image is None:
        raise FileNotFoundError(source)
    height, width = image.shape[:2]
    red = image[:, :, 2].astype(np.float32)
    green = image[:, :, 1].astype(np.float32)
    sky_green = np.percentile(green[:, int(width * .45):int(width * .55)], 75, axis=1)
    sky_red = np.percentile(red[:, int(width * .45):int(width * .55)], 75, axis=1)
    fy = np.arange(height)[:, None] / height
    fx = np.arange(width)[None, :] / width
    foliage = np.maximum(
        (sky_green[:, None] * .73 - green) / np.maximum(10, sky_green[:, None] * .16),
        (sky_red[:, None] * .53 - red) / np.maximum(18, sky_red[:, None] * .13),
    )
    foliage = np.where(fy < .22, np.minimum(foliage, (35 - green) / 15), foliage)
    mask = np.where(foliage > .49, 255, 0).astype(np.uint8)
    mask = np.where((fy < .13) & (fx < .50), 0, mask).astype(np.uint8)
    components, labels, stats, _ = cv2.connectedComponentsWithStats(mask, 8)
    cleaned_mask = np.zeros_like(mask)
    for component in range(1, components):
        x, y, w, h, area = stats[component]
        if area > 300 and (x < 25 or x + w > width - 25 or y < 10 or y + h > height - 10):
            cleaned_mask[labels == component] = 255
    mask = cleaned_mask
    coverage = np.mean(mask > 0)
    if not (.18 < coverage < .46):
        raise RuntimeError(f"Unexpected palm foliage coverage: {coverage:.3f}")
    sky = cv2.inpaint(image, cv2.dilate(mask, np.ones((5, 5), np.uint8)),
                      14, cv2.INPAINT_TELEA)

    def save(name, pixels):
        if platform == "ios":
            image_set = output / f"{name}.imageset"
            image_set.mkdir(parents=True, exist_ok=True)
            file_name = "background.jpg" if name == "ViceSky" else "fronds.png"
            destination = image_set / file_name
            (image_set / "Contents.json").write_text(json.dumps({
                "images": [{"filename": file_name, "idiom": "universal"}],
                "info": {"author": "xcode", "version": 1}
            }), encoding="utf-8")
        else:
            destination = output / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.suffix.lower() == ".jpg":
            ok = cv2.imwrite(str(destination), pixels, [cv2.IMWRITE_JPEG_QUALITY, 94])
        else:
            ok = cv2.imwrite(str(destination), pixels, [cv2.IMWRITE_PNG_COMPRESSION, 7])
        if not ok:
            raise RuntimeError(f"Cannot write {destination}")
        print(f"Prepared {destination} ({destination.stat().st_size} bytes)")

    save("ViceSky" if platform == "ios" else "vice_sky.jpg", sky)
    for index in range(3):
        if index == 0:
            region = fx < .55
        elif index == 1:
            region = (fx >= .55) & (fy < .57)
        else:
            region = (fx >= .55) & (fy >= .57)
        alpha = cv2.GaussianBlur(
            mask * np.broadcast_to(region, mask.shape).astype(np.uint8),
            (3, 3), .5
        )
        rgba = cv2.cvtColor(image, cv2.COLOR_BGR2BGRA)
        rgba[:, :, 3] = alpha
        rgba[alpha == 0, :3] = 0
        save(f"ViceFronds{index}" if platform == "ios" else f"vice_fronds_{index}.png", rgba)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform", choices=["ios", "android", "windows"], required=True)
    arguments = parser.parse_args()
    if arguments.platform == "ios":
        source = Path("NightwellMusic/Assets.xcassets/ViceSunset.imageset/background.jpg")
        output = Path("NightwellMusic/Assets.xcassets")
    elif arguments.platform == "android":
        source = Path("android/app/src/main/res/drawable-nodpi/vice_sunset.jpg")
        output = Path("android/app/src/main/res/drawable-nodpi")
    else:
        source = Path("windows/vice_sunset.jpg")
        output = Path("windows")
    make_assets(source, output, arguments.platform)
