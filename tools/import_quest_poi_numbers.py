"""Import Forever FrameXML's complete quest-number atlas.

Forever's `UI-QuestPoi-NumberIcons` keeps the normal quest circle and the
numbers 1-25 in separate 32x32 regions. Its FrameXML composes those regions as
separate layers. UnrealQuest retains that separation with one map Button per
layer because this client's confirmed custom-map-pin contract is one
BACKGROUND texture per Button.

Run from the addon root:

    python tools/import_quest_poi_numbers.py [source PNG]

When omitted, the source is discovered in the sibling ForeverFrameXML addon.
"""

import glob
import os
import sys

from PIL import Image


def find_source():
    if len(sys.argv) > 1:
        return os.path.abspath(sys.argv[1])
    addon_parent = os.path.dirname(os.getcwd())
    pattern = os.path.join(
        addon_parent,
        "ForeverFrameXML-*",
        "wowdata-art-ui",
        "interface",
        "worldmap",
        "ui-questpoi-numbericons.png",
    )
    matches = sorted(glob.glob(pattern))
    if not matches:
        raise FileNotFoundError("UI-QuestPoi-NumberIcons source PNG not found")
    return matches[-1]


def write_tga_rle(image, path):
    image.save(path, format="TGA", compression="tga_rle")
    with open(path, "rb") as handle:
        header = handle.read(18)
    if len(header) != 18 or header[2] != 10 or header[16] != 32 or header[17] != 8:
        raise ValueError("RLE TGA writer did not produce the proven type-10 header")


def main():
    source_path = find_source()
    source = Image.open(source_path).convert("RGBA")
    if source.size != (256, 256):
        raise ValueError("expected a 256x256 UI-QuestPoi-NumberIcons source")
    output = os.path.join(os.getcwd(), "media", "UIQuestPOINumberIcons.tga")
    write_tga_rle(source, output)
    if Image.open(output).convert("RGBA").tobytes() != source.tobytes():
        raise ValueError("RLE encoding changed the imported quest-number atlas")
    print("UIQuestPOINumberIcons.tga: %d bytes" % os.path.getsize(output))


if __name__ == "__main__":
    main()
