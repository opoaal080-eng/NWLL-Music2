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
    # One broad matte for cleaning the stationary sky; a STRICTER matte for
    # animated fronds. The old max() mask was putting bright pink sky pixels
    # into the rotating leaf layers, producing blurry rectangular trails.
    green_dark = (sky_green[:, None] * .73 - green) / np.maximum(10, sky_green[:, None] * .16)
    red_dark = (sky_red[:, None] * .53 - red) / np.maximum(18, sky_red[:, None] * .13)
    remove_strength = np.maximum(green_dark, red_dark)
    leaf_strength = np.minimum(green_dark, red_dark)
    limit = (35 - green) / 15
    remove_strength = np.where(fy < .22, np.minimum(remove_strength, limit), remove_strength)
    leaf_strength = np.where(fy < .22, np.minimum(leaf_strength, limit), leaf_strength)
    no_silhouettes = (fy < .13) & (fx < .50)

    def binary(threshold_values):
        result = np.where(threshold_values > .49, 255, 0).astype(np.uint8)
        result[no_silhouettes] = 0
        return result

    def keep_edge_fronds(source_mask, with_groups):
        count, labels, stats, _ = cv2.connectedComponentsWithStats(source_mask, 8)
        full_mask = np.zeros_like(source_mask)
        grouped = [np.zeros_like(source_mask) for _ in range(3)]
        for component in range(1, count):
            x, y, w, h, area = stats[component]
            if area <= 300 or not (x < 25 or x+w > width-25 or y < 10 or y+h > height-10):
                continue
            region = labels == component
            full_mask[region] = 255
            if with_groups:
                # Keep whole fronds together, never clip them at x=55%.
                section = 0 if x < 25 else (1 if y < height * .56 else 2)
                grouped[section][region] = 255
        return full_mask, grouped

    removal_mask, _ = keep_edge_fronds(binary(remove_strength), False)
    strict_mask = cv2.morphologyEx(binary(leaf_strength), cv2.MORPH_CLOSE,
                                    cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3)))
    mask, group_masks = keep_edge_fronds(strict_mask, True)
    coverage = float(np.mean(mask > 0))
    if not (.18 < coverage < .45):
        raise RuntimeError(f"Unexpected palm foliage coverage: {coverage:.3f}")

    # Exclude fringe/old silhouettes as well as original palm pixels, then
    # reconstruct the missing sky using *only* neighboring unoccluded colors.
    # This avoids inpainting streaks, static ghost silhouettes and pink smears.
    dilate_size = max(25, int(round(width * .09)) | 1)
    excluded = cv2.dilate(removal_mask,
                          cv2.getStructuringElement(cv2.MORPH_ELLIPSE,
                                                    (dilate_size, dilate_size)))
    visible_sky = (255 - excluded).astype(np.float32) / 255
    sigma = max(36.0, width * .117)
    weighted_rgb = cv2.GaussianBlur(image.astype(np.float32) * visible_sky[:, :, None],
                                    (0, 0), sigma)
    weighted_sky = cv2.GaussianBlur(visible_sky, (0, 0), sigma)
    # Don't clamp to .015: it caused black corners under large palm canopies.
    reconstructed = weighted_rgb / np.maximum(weighted_sky[:, :, None], 1.e-8)
    feather = cv2.GaussianBlur(excluded, (0, 0),
                               max(5.0, width * .012)).astype(np.float32) / 255
    sky = np.clip(image.astype(np.float32) * (1 - feather[:, :, None]) +
                  reconstructed * feather[:, :, None], 0, 255).astype(np.uint8)

    # Regression for the exact warm-sky area that looked like a fuzzy rectangle
    # when a frond moved. Only real leaf pixels can be inside a moving layer.
    check_y = int(height * 1160 / 1672)
    check_x = int(width * 12 / 941)
    if any(group[check_y, check_x] != 0 for group in group_masks):
        raise RuntimeError("Moving foliage still contains sunset sky")

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
            ok = cv2.imwrite(str(destination), pixels, [cv2.IMWRITE_JPEG_QUALITY, 97])
        else:
            ok = cv2.imwrite(str(destination), pixels, [cv2.IMWRITE_PNG_COMPRESSION, 7])
        if not ok:
            raise RuntimeError(f"Cannot write {destination}")
        print(f"Prepared {destination} ({destination.stat().st_size} bytes)")

    save("ViceSky" if platform == "ios" else "vice_sky.jpg", sky)
    for index in range(3):
        alpha = cv2.GaussianBlur(group_masks[index], (3, 3), .5)
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
