"""Brightened hover copies of the V2 and light themes' reward tile art.

A hovered reward tile swaps its plate and left edge for these copies: the
same art with the colour channels lifted by BRIGHTEN, alpha untouched. The
client clamps a vertex colour at 1 and an additive overlay showed no effect
in game, so the brighter look is baked into a texture instead.

Writes <name>_Hover.tga beside each source, RLE TGA type 10 with descriptor
0x08, like every addon TGA here.

Run from the addon root:  python tools/make_reward_hover.py
"""

import os

from PIL import Image, ImageEnhance

FOLDER = os.path.join(os.getcwd(), "media", "Textures", "Dialogues")
BRIGHTEN = 1.2
V2_SOURCES = (
    "Reward_Item_Plate_Unified",
    "Reward_Item_Plate_Unified_Selected",
    "Reward_Plate_Left_Edge",
)
# (folder, texture prefix, sources) per theme. A light theme's reward tile is
# its banner plate alone, with no left edge.
THEMES = (
    ("Alliance", "Alliance", V2_SOURCES),
    ("Horde", "Horde", V2_SOURCES),
    ("HordeLight", "HordeLight", ("Plate", "Plate_Selected")),
    ("AllianceLight", "AllianceLight", ("Plate", "Plate_Selected")),
)


def write_tga_rle(image, path):
    image = image.convert("RGBA")
    image.save(path, format="TGA", compression="tga_rle")
    with open(path, "rb") as handle:
        header = handle.read(18)
    if len(header) != 18 or header[2] != 10 or header[16] != 32 or header[17] != 8:
        raise ValueError("RLE TGA writer did not produce the proven type-10 header")
    return os.path.getsize(path)


def brighten(path, output):
    image = Image.open(path).convert("RGBA")
    alpha = image.getchannel("A")
    lifted = ImageEnhance.Brightness(image.convert("RGB")).enhance(BRIGHTEN).convert("RGBA")
    lifted.putalpha(alpha)
    return write_tga_rle(lifted, output)


def main():
    for folder, prefix, sources in THEMES:
        for source in sources:
            stem = os.path.join(FOLDER, folder, "UQ_" + prefix + "_" + source)
            size = brighten(stem + ".tga", stem + "_Hover.tga")
            print("%s_Hover.tga  %d bytes" % (os.path.basename(stem), size))


if __name__ == "__main__":
    main()
