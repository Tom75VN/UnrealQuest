"""Build the Minimal dialogue theme's grain texture and its card border.

The grain adds quiet material variation to the Lua-tinted card fill. The
mirrored 2x2 build makes every edge tile exactly.

The card border is unrealUI's thin border, copied into #src/Minimal. Only its
bottom-left corner and bottom edge are used: that set ships no bottom-right
corner, and building all four corners from one keeps them identical. The
other corners are mirrors of it; the side edges repeat the corner's vertical
arm so they meet it seamlessly, the top edge is the flipped bottom edge. Each
piece is 32x32, the line on its outer side.

The source carries a soft drop shadow on the line's outer side, which drew a
dark halo outside the card (user report, 2026-10-12). It is cleared before the
pieces are built: every translucent pixel reachable from the outer edges
without crossing the opaque line goes fully transparent. The inner shadow,
over the card's own fill, stays.

The two quest buttons (Accept / Decline) wear unrealUI's key-binding face:
its silver stretch button (ui-silver-button-up / -down / -highlight, the
UIMenuButtonStretchTemplate sheets), copied into #src/Minimal unchanged and
written here as UQ_Minimal_Button_Up / _Down / _Highlight. Lua cuts the 128x32
up and down sheets nine ways (QUEST_DIALOGUE_MINIMAL.ACTION_BUTTON.SILVER).
The up and down sheets' translucent black centre (about 50% opaque) is made
60% more opaque here (BUTTON_OPACITY, user requests 2026-10-12): a vertex
colour can only lower a texture's alpha, never raise it.

Everything is written as the proven 32-bit RLE TGA type 10.

Run from the addon root:  python tools/make_dialogue_minimal.py
"""

import os

from PIL import Image, ImageEnhance, ImageOps


ROOT = os.getcwd()
SOURCE = os.path.join(
    ROOT, "media", "Textures", "Dialogues", "#src", "Minimal",
    "minimal-grain-source.png",
)
OUTPUT = os.path.join(
    ROOT, "media", "Textures", "Dialogues", "Minimal", "UQ_Minimal_Grain.tga",
)
SIZE = 256
BORDER_SOURCE = os.path.join(ROOT, "media", "Textures", "Dialogues", "#src", "Minimal")
BORDER_OUTPUT = os.path.join(
    ROOT, "media", "Textures", "Dialogues", "Minimal", "UQ_Minimal_Border_%s.tga",
)


def write_tga_rle(image, path):
    image.convert("RGBA").save(path, format="TGA", compression="tga_rle")
    with open(path, "rb") as handle:
        header = handle.read(18)
    if len(header) != 18 or header[2] != 10 or header[16] != 32 or header[17] != 8:
        raise ValueError("RLE TGA writer did not produce the proven type-10 header")


def clear_outer_shadow(image, seeds):
    """Zero every non-opaque pixel connected to `seeds` through non-opaque
    pixels: the shadow outside the line, which the opaque line walls off."""
    pixels = image.load()
    width, height = image.size
    stack = [seed for seed in seeds if pixels[seed][3] < 255]
    seen = set(stack)
    while stack:
        x, y = stack.pop()
        pixels[x, y] = (0, 0, 0, 0)
        for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
            if 0 <= nx < width and 0 <= ny < height and (nx, ny) not in seen \
                    and pixels[nx, ny][3] < 255:
                seen.add((nx, ny))
                stack.append((nx, ny))
    return image


def build_border():
    corner = Image.open(os.path.join(BORDER_SOURCE, "thin-border-bottom-left.tga")).convert("RGBA")
    bottom = Image.open(os.path.join(BORDER_SOURCE, "thin-border-bottom.tga")).convert("RGBA")
    if corner.size != (32, 32) or bottom.size != (32, 32):
        raise ValueError("thin border sources are expected at 32x32")
    # Outer sides: the corner's left column and bottom row, the edge's bottom row.
    clear_outer_shadow(corner, [(0, y) for y in range(32)] + [(x, 31) for x in range(32)])
    clear_outer_shadow(bottom, [(x, 31) for x in range(32)])
    # The corner's top row is the cross-section of its vertical arm.
    left = corner.crop((0, 0, 32, 1)).resize((32, 32), Image.Resampling.NEAREST)
    pieces = {
        "BL": corner,
        "BR": ImageOps.mirror(corner),
        "TL": ImageOps.flip(corner),
        "TR": ImageOps.flip(ImageOps.mirror(corner)),
        "B": bottom,
        "T": ImageOps.flip(bottom),
        "L": left,
        "R": ImageOps.mirror(left),
    }
    for name, image in pieces.items():
        write_tga_rle(image, BORDER_OUTPUT % name)
        print(BORDER_OUTPUT % name)


BUTTON_OPACITY = 1.6


def build_buttons():
    for state, name in (("up", "Up"), ("down", "Down"), ("highlight", "Highlight")):
        source = Image.open(os.path.join(
            BORDER_SOURCE, "ui-silver-button-%s.tga" % state)).convert("RGBA")
        if source.size != (128, 32):
            raise ValueError("silver button sheets are expected at 128x32")
        if state != "highlight":
            red, green, blue, alpha = source.split()
            alpha = alpha.point(lambda value: min(255, int(round(value * BUTTON_OPACITY))))
            source = Image.merge("RGBA", (red, green, blue, alpha))
        output = os.path.join(
            ROOT, "media", "Textures", "Dialogues", "Minimal",
            "UQ_Minimal_Button_%s.tga" % name)
        write_tga_rle(source, output)
        print(output)


def main():
    source = Image.open(SOURCE).convert("RGB")
    half = source.resize((SIZE // 2, SIZE // 2), Image.Resampling.LANCZOS)
    half = ImageEnhance.Color(half).enhance(0.60)
    half = ImageEnhance.Contrast(half).enhance(0.62)
    image = Image.new("RGB", (SIZE, SIZE))
    image.paste(half, (0, 0))
    image.paste(ImageOps.mirror(half), (SIZE // 2, 0))
    image.paste(ImageOps.flip(half), (0, SIZE // 2))
    image.paste(ImageOps.flip(ImageOps.mirror(half)), (SIZE // 2, SIZE // 2))
    write_tga_rle(image, OUTPUT)
    print(OUTPUT)
    build_border()
    build_buttons()


if __name__ == "__main__":
    main()
