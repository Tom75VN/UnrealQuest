"""Mend the light themes' quest card rails where they repeat.

Making the quest card taller (BODY_CUT_TALL in make_dialogue_horde_light.py)
repeats a 12-row band of each rail just above its seam, which reads as a
repeating texture: a stack of near-identical spikes on the parchment's torn
edge. Each seam sits at its own row, so at those rows the other rail is
clean. A mend replaces a repeated stretch of one rail with the other rail
mirrored, feathered into the rail above and below and into the parchment, so
the two rails read as a pair.

- Alliance light: the right rail's gold spikes above its sapphire, mended
  from the left rail (both sapphires sit on the same rows, y 255..285).
- Horde light: the left rail's spikes at y 186..216 from the right rail, and
  the right rail's at y 224..258 from the left (measured on the shipped
  tiles: a 7-row sawtooth on the parchment's torn edge, the 12 source rows
  at the card's 0.5947 vertical scale).

Coordinates are in the composed 1024x512 card (the tools crop the card and
resize it to that before cutting the TL/TR/BL/BR tiles): both rails start 20
px inside the card's edge.

make_dialogue_alliance_light.py and make_dialogue_horde_light.py call mend() on the
composed quest card. Run alone, it mends a theme's shipped tiles in place
(when the #src masters are not at hand):

    python tools/mend_dialogue_rail.py alliance
    python tools/mend_dialogue_rail.py horde-light

The client keeps decoded textures across /reload
(textures.resources_cached_across_ui_reload): restart it to see new tiles.
"""

import os
import sys

from PIL import Image, ImageOps

# A mend: the rows replaced, and the rail they are replaced on.
ALLIANCE_MENDS = ((200, 306, "right"),)
HORDE_LIGHT_MENDS = ((182, 220, "left"), (220, 262, "right"))
# Rows at each end of a mend blended into the existing rail.
ROW_FEATHER = 6
# Columns replaced, counted from the card's edge, and the columns at their
# inner end blended into the parchment.
WIDTH, COLUMN_FEATHER = 52, 12

DIALOGUES = os.path.join(os.getcwd(), "media", "Textures", "Dialogues")
THEMES = {
    "alliance-light": (os.path.join(DIALOGUES, "AllianceLight"), "UQ_AllianceLight_CardTall_",
                 ALLIANCE_MENDS),
    "horde-light": (os.path.join(DIALOGUES, "HordeLight"), "UQ_HordeLight_CardTall_",
                    HORDE_LIGHT_MENDS),
}
QUARTERS = (("TL", 0, 0), ("TR", 512, 0), ("BL", 0, 256), ("BR", 512, 256))


def mend(whole, mends=ALLIANCE_MENDS):
    """Return the 1024x512 quest card with each of `mends` applied."""
    whole = whole.convert("RGBA")
    width = whole.size[0]
    for top, bottom, side in mends:
        # The other rail, mirrored onto this side.
        mirrored = ImageOps.mirror(whole)
        left = 0 if side == "left" else width - WIDTH
        box = (left, top, left + WIDTH, bottom)
        mask = Image.new("L", (WIDTH, bottom - top), 0)
        for y in range(bottom - top):
            row = min(1.0, (y + 1) / float(ROW_FEATHER),
                      (bottom - top - y) / float(ROW_FEATHER))
            for x in range(WIDTH):
                # The inner end faces the parchment.
                inner = WIDTH - x if side == "left" else x + 1
                column = min(1.0, inner / float(COLUMN_FEATHER))
                mask.putpixel((x, y), int(round(255 * row * column)))
        whole.paste(Image.composite(mirrored.crop(box), whole.crop(box), mask),
                    (left, top))
    return whole


def write_tga(image, path):
    image.convert("RGBA").save(path, format="TGA", compression="tga_rle")
    with open(path, "rb") as handle:
        header = handle.read(18)
    if len(header) != 18 or header[2] != 10 or header[16] != 32 or header[17] != 8:
        raise ValueError("Dialogue texture is not a 32-bit RLE type-10 TGA: " + path)


def main(theme):
    tiles, prefix, mends = THEMES[theme]
    whole = Image.new("RGBA", (1024, 512))
    for suffix, left, top in QUARTERS:
        tile = Image.open(os.path.join(tiles, prefix + suffix + ".tga")).convert("RGBA")
        whole.paste(tile, (left, top))
    whole = mend(whole, mends)
    for suffix, left, top in QUARTERS:
        write_tga(whole.crop((left, top, left + 512, top + 256)),
                  os.path.join(tiles, prefix + suffix + ".tga"))
        print(prefix + suffix + ".tga")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "alliance-light")
