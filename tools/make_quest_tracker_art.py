"""Build the quest tracker window's texture atlas, media/QuestTracker.tga.

Source: `media/8268353.png`, the WoW Forever (build 1.60.1.69913) objective
tracker sheet, FileDataID 8268353 / UiTextureAtlas 4197 (1024x512, drawn at
twice the interface's own scale). The rectangles below are that atlas's
UiTextureAtlasMember rows for the pieces the tracker draws.

Each piece is cut from the sheet, the two header bars trimmed to their
visible pixels, reduced to half size (the interface's own scale) with
premultiplied alpha, and packed into a 512x512 32-bit RLE TGA (image type 10,
descriptor 0x08): the only addon atlas form measured to render on this client
(textures.uncompressed_512_tga_atlas_corrupts,
textures.rle_512_tga_atlas_four_arg_supported). The sheet itself is never
loaded by the client.

Prints the packed rectangles as the Lua table Compatibility/ClientAPI.lua's
TrackerArt.pieces carries. A source that is not present keeps the
already-built TGA.

Run from the addon root:

    python tools/make_quest_tracker_art.py
"""

import os
import sys

from PIL import Image

SOURCE = os.path.join("media", "8268353.png")
OUTPUT = os.path.join("media", "QuestTracker.tga")
ATLAS = 512
GUTTER = 2
# Alpha below which a header row or column counts as empty when trimming.
TRIM_ALPHA = 8

# (name, UiTextureAtlasMember left, top, right, bottom on the 1024x512 sheet,
#  trim to visible pixels)
PIECES = [
    ("header", 1, 241, 601, 321, True),      # UI-QuestTracker-Primary-Objective-Header
    ("zone", 1, 323, 601, 383, True),        # UI-QuestTracker-Secondary-Objective-Header
    ("collapse", 951, 59, 987, 97, False),   # UI-QuestTrackerButton-Collapse-All
    ("expand", 905, 161, 941, 199, False),   # UI-QuestTrackerButton-Expand-All
    ("highlight", 943, 161, 979, 199, False),  # UI-QuestTrackerButton-Red-Highlight
    ("zoneCollapse", 989, 59, 1021, 91, False),  # UI-QuestTrackerButton-Secondary-Collapse
    ("zoneExpand", 981, 161, 1013, 193, False),  # UI-QuestTrackerButton-Secondary-Expand
    ("nub", 977, 1, 1015, 39, False),        # UI-QuestTracker-Objective-Nub
    ("check", 871, 59, 909, 97, False),      # UI-QuestTracker-Tracker-Check
]


def write_tga_rle(image, path):
    image.save(path, format="TGA", compression="tga_rle")
    with open(path, "rb") as handle:
        header = handle.read(18)
    if len(header) != 18 or header[2] != 10 or header[16] != 32 or header[17] != 8:
        raise ValueError("RLE TGA writer did not produce the proven type-10 header")
    if Image.open(path).convert("RGBA").tobytes() != image.tobytes():
        raise ValueError("RLE encoding changed " + path)


def trimmed(piece):
    alpha = piece.getchannel("A").point(lambda value: 255 if value >= TRIM_ALPHA else 0)
    box = alpha.getbbox()
    if not box:
        raise ValueError("empty piece")
    left, top, right, bottom = box
    # Even edges keep the half-size reduction pixel exact.
    left -= left % 2
    top -= top % 2
    right += right % 2
    bottom += bottom % 2
    return piece.crop((left, top, right, bottom))


def halved(piece):
    width, height = piece.size
    reduced = piece.convert("RGBa").resize((width // 2, height // 2), Image.LANCZOS)
    return reduced.convert("RGBA")


def main():
    if not os.path.exists(SOURCE):
        print("source missing, keeping " + OUTPUT)
        return 0
    sheet = Image.open(SOURCE).convert("RGBA")
    if sheet.size != (1024, 512):
        raise ValueError("unexpected sheet size %dx%d" % sheet.size)

    atlas = Image.new("RGBA", (ATLAS, ATLAS), (0, 0, 0, 0))
    x = GUTTER
    y = GUTTER
    shelf = 0
    rects = []
    for name, left, top, right, bottom, trim in PIECES:
        piece = sheet.crop((left - left % 2, top - top % 2, right + right % 2, bottom + bottom % 2))
        if trim:
            piece = trimmed(piece)
        piece = halved(piece)
        width, height = piece.size
        if x + width + GUTTER > ATLAS:
            x = GUTTER
            y = y + shelf + GUTTER
            shelf = 0
        if y + height + GUTTER > ATLAS:
            raise ValueError("atlas full at " + name)
        atlas.alpha_composite(piece, (x, y))
        rects.append((name, x, y, width, height))
        x = x + width + GUTTER
        shelf = max(shelf, height)
        # The two header bars get a shelf each.
        if trim:
            x = ATLAS

    write_tga_rle(atlas, OUTPUT)
    print("wrote " + OUTPUT)
    for name, left, top, width, height in rects:
        print("        %s = { %d, %d, %d, %d }," % (name, left, top, width, height))
    return 0


if __name__ == "__main__":
    sys.exit(main())
