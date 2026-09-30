#!/usr/bin/env python3
"""Derive aligned 960px Rei/Sage sprite layers from transparent original art.

Masters live under design-assets/{rei,sage}/source and stay outside the installed
app. Appendages are extracted deterministically from the original source pixels.
Intact tail-less/wingless edited body masters prevent holes where appendages
overlap hands, hair or clothing. Closed-eye variants contribute only the eyes.
Requires Pillow; run from any directory with `python3 scripts/build_companion_layers.py`.
"""

from pathlib import Path
from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
TARGET = ROOT / "WaifuClaw" / "Local" / "Art"
MASTER_SIZE = (1920, 1920)
OUTPUT_SIZE = (960, 960)

# Coordinates are in original 1920-square, top-origin transparent art.
# These masks cut only the appendages BEHIND the body/arms; roots still overlap
# the torso in SpriteKit, while the cutout prevents double-printed ghost wings.
DESIGNS = {
    "rei": {
        "pieces": [
            ("ReiTailLeft.png", [
                (115, 515), (490, 480), (630, 595), (680, 770),
                (650, 940), (745, 1070), (735, 1200), (690, 1360),
                (480, 1450), (245, 1390), (115, 1270), (80, 1030),
            ]),
            ("ReiTailRight.png", [
                (1200, 850), (1490, 850), (1770, 950), (1840, 1160),
                (1830, 1410), (1710, 1650), (1560, 1720), (1350, 1650),
                (1220, 1450), (1190, 1190), (1100, 920),
            ]),
        ],
        "body": "ReiBody.png",
        "bodySource": "rei-body-without-tails.png",
        "blink": "ReiBlinkEyes.png",
        "eyes": (785, 264, 1190, 480),
    },
    "sage": {
        "pieces": [
            ("SageWingLeft.png", [
                (0, 75), (210, 115), (450, 210), (620, 300),
                (680, 390), (655, 505), (600, 660), (460, 850),
                (220, 900), (0, 790),
            ]),
            ("SageWingRight.png", [
                (1920, 75), (1710, 115), (1470, 210), (1300, 300),
                (1240, 390), (1265, 505), (1320, 660), (1460, 850),
                (1700, 900), (1920, 790),
            ]),
        ],
        "body": "SageBody.png",
        "bodySource": "sage-body-without-wings.png",
        "blink": "SageBlinkEyes.png",
        "eyes": (770, 190, 1160, 370),
    },
}


def open_master(path: Path) -> Image.Image:
    image = Image.open(path).convert("RGBA")
    if image.size != MASTER_SIZE or image.getchannel("A").getextrema()[0] != 0:
        raise ValueError(f"{path}: expected 1920-square image with native alpha")
    return image


def polygon_mask(points: list[tuple[int, int]]) -> Image.Image:
    mask = Image.new("L", MASTER_SIZE, 0)
    ImageDraw.Draw(mask).polygon(points, fill=255)
    return mask.filter(ImageFilter.GaussianBlur(radius=2))


def cutout(image: Image.Image, mask: Image.Image) -> Image.Image:
    layer = image.copy()
    layer.putalpha(ImageChops.multiply(image.getchannel("A"), mask))
    return layer


def eye_overlay(image: Image.Image, box: tuple[int, int, int, int]) -> Image.Image:
    mask = Image.new("L", MASTER_SIZE, 0)
    ImageDraw.Draw(mask).ellipse(box, fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(radius=12))
    return cutout(image, mask)


def output(image: Image.Image, filename: str) -> Image.Image:
    scaled = image.resize(OUTPUT_SIZE, Image.Resampling.LANCZOS)
    path = TARGET / filename
    scaled.save(path, optimize=True)
    if Image.open(path).getchannel("A").getextrema()[0] != 0:
        raise ValueError(f"{filename}: transparent background lost")
    print(path.relative_to(ROOT), path.stat().st_size, "bytes")
    return scaled


def build(name: str, design: dict) -> None:
    master_dir = ROOT / "design-assets" / name / "source"
    original = open_master(master_dir / f"{name}-base.png")
    closed = open_master(master_dir / f"{name}-eyes-closed.png")
    pieces: list[Image.Image] = []
    for filename, polygon in design["pieces"]:
        mask = polygon_mask(polygon)
        pieces.append(output(cutout(original, mask), filename))

    body_layer = output(open_master(master_dir / design["bodySource"]), design["body"])
    blink_layer = output(eye_overlay(closed, design["eyes"]), design["blink"])

    preview = Image.new("RGBA", OUTPUT_SIZE, (0, 0, 0, 0))
    for piece in pieces:
        preview.alpha_composite(piece)
    preview.alpha_composite(body_layer)
    preview_on_dark = Image.new("RGBA", OUTPUT_SIZE, (19, 13, 34, 255))
    preview_on_dark.alpha_composite(preview)
    preview_on_dark.save(ROOT / "design-assets" / name / "composite-on-dark.png")
    print("QA preview:", (ROOT / "design-assets" / name / "composite-on-dark.png").relative_to(ROOT))
    if blink_layer.getchannel("A").getbbox() is None:
        raise ValueError(f"{name}: closed-eye overlay is empty")


def main() -> None:
    TARGET.mkdir(parents=True, exist_ok=True)
    for name, design in DESIGNS.items():
        build(name, design)


if __name__ == "__main__":
    main()
