#!/usr/bin/env python3
"""Build Kline's pixel-aligned body, wing, and eyelid sprite textures.

Art masters live in design-assets/kline/source; the native iOS target bundles only
optimized layers under WaifuClaw/Local/Art. The generated art is derived from
artwork provided for this project. Requires Pillow: python3 -m pip install Pillow.
"""

from pathlib import Path
from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "design-assets" / "kline" / "source"
TARGET = ROOT / "WaifuClaw" / "Local" / "Art"
ORIGINAL_SIZE = (1920, 1920)
OUTPUT_SIZE = (960, 960)
WING_SPLIT_X = 790


def open_master(name: str) -> Image.Image:
    image = Image.open(SOURCE / name).convert("RGBA")
    if image.size != ORIGINAL_SIZE or image.getchannel("A").getextrema()[0] != 0:
        raise ValueError(f"{name}: expected a 1920-square sprite with real alpha")
    return image


def isolated_wing(image: Image.Image, *, left: bool, shift_x: int) -> Image.Image:
    mask = Image.new("L", ORIGINAL_SIZE, 0)
    drawer = ImageDraw.Draw(mask)
    if left:
        drawer.rectangle((0, 0, WING_SPLIT_X, ORIGINAL_SIZE[1]), fill=255)
    else:
        drawer.rectangle((WING_SPLIT_X + 1, 0, ORIGINAL_SIZE[0], ORIGINAL_SIZE[1]), fill=255)
    part = image.copy()
    part.putalpha(ImageChops.multiply(part.getchannel("A"), mask))
    canvas = Image.new("RGBA", ORIGINAL_SIZE, (0, 0, 0, 0))
    # Align the wing hinge under its shoulder, preserving native transparency.
    canvas.paste(part, (shift_x, -290))
    return canvas


def blink_overlay(image: Image.Image) -> Image.Image:
    # Feather only the changed eyes. This is a separate facial animation frame,
    # not a full-body crossfade, so the rest of the rig remains stationary.
    feather = Image.new("L", ORIGINAL_SIZE, 0)
    drawer = ImageDraw.Draw(feather)
    drawer.ellipse((625, 260, 940, 389), fill=255)
    feather = feather.filter(ImageFilter.GaussianBlur(13))
    eyes = image.copy()
    eyes.putalpha(ImageChops.multiply(eyes.getchannel("A"), feather))
    return eyes


def save_layer(image: Image.Image, name: str) -> Image.Image:
    image = image.resize(OUTPUT_SIZE, Image.Resampling.LANCZOS)
    output = TARGET / name
    image.save(output, optimize=True)
    if Image.open(output).getchannel("A").getextrema()[0] != 0:
        raise ValueError(f"{name}: alpha lost during downscale")
    print(output.relative_to(ROOT), output.stat().st_size, "bytes")
    return image


def main() -> None:
    TARGET.mkdir(parents=True, exist_ok=True)
    body = save_layer(open_master("kline-body.png"), "KlineBody.png")
    wing_master = open_master("kline-wings.png")
    left = save_layer(isolated_wing(wing_master, left=True, shift_x=-65), "KlineWingLeft.png")
    right = save_layer(isolated_wing(wing_master, left=False, shift_x=75), "KlineWingRight.png")
    save_layer(blink_overlay(open_master("kline-blink.png")), "KlineBlinkEyes.png")

    # Visual QA only: composition is not bundled in the installed app.
    composite = Image.new("RGBA", OUTPUT_SIZE, (0, 0, 0, 0))
    composite.alpha_composite(left)
    composite.alpha_composite(right)
    composite.alpha_composite(body)
    preview = ROOT / "design-assets" / "kline" / "composite-preview.png"
    composite.save(preview, optimize=True)
    print(preview.relative_to(ROOT), "QA preview")


if __name__ == "__main__":
    main()
