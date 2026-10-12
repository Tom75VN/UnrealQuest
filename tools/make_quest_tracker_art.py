"""Build the quest tracker window's texture sheet, media/Textures/Tracker/QuestTrackerSheet.tga.

Source: `8268353.png` (outside the addon folder, see SOURCE below), the WoW Forever (build 1.60.1.69913) objective
tracker sheet, FileDataID 8268353 / UiTextureAtlas 4197 (1024x512, drawn at
twice the interface's own scale).

The PNG is converted to a 32-bit RLE TGA (image type 10, descriptor 0x08,
textures.rle_512_tga_atlas_four_arg_supported) with every pixel unchanged:
no crop, no resize, no premultiplication, no repacking. The written file is
decoded again and compared byte for byte, all four channels, against the
source; any difference aborts. The client scales each element itself when it
draws it.

Every element on the sheet is then located. MEMBERS carries the atlas's own
UiTextureAtlasMember rows (ForeverFrameXML `query.py filedata 8268353`);
every drawn pixel of the sheet must fall inside a member (any left over is
segmented into connected regions and reported), and each member must hold
drawn pixels, so a row that does not match the image aborts instead of
shipping a blank cell. The two header bars are trimmed to their visible
pixels, the line glow to every pixel it draws, and the quest-item frame to its
visible chamfered square: the frames the tracker's and the Minimal dialogue's
layouts were tuned on.

Prints the rectangles as the Lua table Compatibility/ClientAPI.lua's
TrackerArt.pieces carries. A source that is not present keeps the
already-built TGA.

Run from the addon root:

    python tools/make_quest_tracker_art.py
"""

import os
import sys

from PIL import Image

# Generator input lives outside the addon folder (override with UQ_SOURCE_ART).
SOURCE = os.path.join(os.environ.get("UQ_SOURCE_ART", "D:/Development/unrealQuest_Data/#backup/unrealQuest-media"), "8268353.png")
OUTPUT = os.path.join("media", "Textures", "Tracker", "QuestTrackerSheet.tga")
SHEET = (1024, 512)
# Regions smaller than this many pixels are stray specks, not elements.
SPECK = 4
# Members sit one pixel apart, and a soft glow bleeds into that gutter.
GUTTER = 1

# (piece, UiTextureAtlasMember, left, top, width, height in sheet pixels,
#  alpha a pixel needs to survive trimming the box, 0 to keep the member's box)
MEMBERS = [
    ("progressFrame", "UI-QuestTracker-Progressbar-Frame", 1, 1, 558, 118, 0),
    ("progressChannel", "UI-QuestTracker-Progressbar-Full-Channel", 1, 121, 558, 118, 0),
    ("header", "UI-QuestTracker-Primary-Objective-Header", 1, 241, 600, 80, 8),
    ("zone", "UI-QuestTracker-Secondary-Objective-Header", 1, 323, 600, 60, 8),
    ("goldLine", "ui-questtracker-objfx_lineglow-c60", 1, 385, 742, 12, 1),
    ("barGlow", "UI-QuestTracker-OBJFX-BarGlow", 561, 1, 374, 56, 0),
    ("shine", "ui-questtracker-objfx-shine-c60", 561, 59, 308, 46, 0),
    ("fail", "UI-QuestTracker-Objective-Fail", 937, 1, 38, 38, 0),
    ("nub", "UI-QuestTracker-Objective-Nub", 977, 1, 38, 38, 0),
    ("check", "UI-QuestTracker-Tracker-Check", 871, 59, 38, 38, 0),
    ("checkGlow", "UI-QuestTracker-Tracker-Check-Glow", 911, 59, 38, 38, 0),
    ("collapse", "UI-QuestTrackerButton-Collapse-All", 951, 59, 36, 38, 0),
    ("collapsePressed", "UI-QuestTrackerButton-Collapse-All-Pressed", 905, 121, 36, 38, 0),
    ("expand", "UI-QuestTrackerButton-Expand-All", 905, 161, 36, 38, 0),
    ("expandPressed", "UI-QuestTrackerButton-Expand-All-Pressed", 905, 201, 36, 38, 0),
    ("filter", "UI-QuestTrackerButton-Filter", 943, 121, 36, 38, 0),
    ("filterPressed", "UI-QuestTrackerButton-Filter-Pressed", 981, 121, 36, 38, 0),
    ("highlight", "UI-QuestTrackerButton-Red-Highlight", 943, 161, 36, 38, 0),
    ("zoneCollapse", "UI-QuestTrackerButton-Secondary-Collapse", 989, 59, 32, 32, 0),
    ("zoneCollapsePressed", "UI-QuestTrackerButton-Secondary-Collapse-Pressed", 943, 201, 32, 32, 0),
    ("zoneExpand", "UI-QuestTrackerButton-Secondary-Expand", 981, 161, 32, 32, 0),
    ("zoneExpandPressed", "UI-QuestTrackerButton-Secondary-Expand-Pressed", 981, 195, 32, 32, 0),
    ("yellowHighlight", "UI-QuestTrackerButton-Yellow-Highlight", 603, 241, 32, 32, 0),
    ("itemFrame", "UI-QuestTrackerButton-QuestItem-Frame", 561, 121, 96, 96, 8),
    ("itemFrameGlow", "UI-QuestTrackerButton-QuestItem-Frame-Glow", 659, 121, 96, 96, 0),
    ("eye", "UI-QuestTracker-LFG-eye", 757, 121, 72, 92, 0),
    ("eyeSelected", "UI-QuestTracker-LFG-eye-selected", 831, 121, 72, 92, 0),
]


def write_tga_rle(image, path):
    image.save(path, format="TGA", compression="tga_rle")
    with open(path, "rb") as handle:
        header = handle.read(18)
    if len(header) != 18 or header[2] != 10 or header[16] != 32 or header[17] != 8:
        raise ValueError("RLE TGA writer did not produce the proven type-10 header")
    written = Image.open(path)
    if written.mode != "RGBA" or written.size != image.size or written.tobytes() != image.tobytes():
        raise ValueError("conversion changed a pixel of " + path)


def regions(drawn, width, height):
    """Bounding boxes of the 8-connected regions of a mask's set pixels."""
    seen = bytearray(width * height)
    found = []
    for start in range(width * height):
        if seen[start] or not drawn[start]:
            continue
        seen[start] = 1
        stack = [start]
        left, top, right, bottom, count = width, height, -1, -1, 0
        while stack:
            index = stack.pop()
            x, y = index % width, index // width
            count += 1
            left, right = min(left, x), max(right, x)
            top, bottom = min(top, y), max(bottom, y)
            for ny in (y - 1, y, y + 1):
                if ny < 0 or ny >= height:
                    continue
                for nx in (x - 1, x, x + 1):
                    if 0 <= nx < width:
                        other = ny * width + nx
                        if not seen[other] and drawn[other]:
                            seen[other] = 1
                            stack.append(other)
        if count >= SPECK:
            found.append((left, top, right + 1, bottom + 1, count))
    return found


def check_members(sheet):
    """Every drawn pixel lies in some member, every member holds pixels."""
    width, height = sheet.size
    drawn = bytearray(sheet.getchannel("A").tobytes())
    # Clear each member's box (and its gutter); whatever is still drawn
    # afterwards is an element no member names.
    for _, _, left, top, w, h, _ in MEMBERS:
        x0, x1 = max(left - GUTTER, 0), min(left + w + GUTTER, width)
        for y in range(max(top - GUTTER, 0), min(top + h + GUTTER, height)):
            drawn[y * width + x0:y * width + x1] = bytes(x1 - x0)
    for left, top, right, bottom, count in regions(drawn, width, height):
        raise ValueError("drawn region %d,%d %dx%d (%d px) is in no atlas member"
                         % (left, top, right - left, bottom - top, count))
    for piece, member, left, top, w, h, _ in MEMBERS:
        if not sheet.crop((left, top, left + w, top + h)).getchannel("A").getbbox():
            raise ValueError(piece + " (" + member + ") is empty on the sheet")


def visible(sheet, left, top, width, height, threshold):
    """The member's box trimmed to the pixels at or above `threshold` alpha."""
    alpha = sheet.crop((left, top, left + width, top + height)).getchannel("A")
    box = alpha.point(lambda value: 255 if value >= threshold else 0).getbbox()
    if not box:
        raise ValueError("nothing visible at %d,%d" % (left, top))
    return left + box[0], top + box[1], box[2] - box[0], box[3] - box[1]


def main():
    if not os.path.exists(SOURCE):
        print("source missing, keeping " + OUTPUT)
        return 0
    sheet = Image.open(SOURCE)
    sheet.load()
    if sheet.mode != "RGBA" or sheet.size != SHEET:
        raise ValueError("unexpected sheet %s %dx%d" % ((sheet.mode,) + sheet.size))

    write_tga_rle(sheet, OUTPUT)
    print("wrote " + OUTPUT + " (pixels identical to " + SOURCE + ")")

    check_members(sheet)
    for piece, member, left, top, width, height, trim in MEMBERS:
        if trim:
            left, top, width, height = visible(sheet, left, top, width, height, trim)
        print("        %s = { %d, %d, %d, %d }, -- %s" % (piece, left, top, width, height, member))
    return 0


if __name__ == "__main__":
    sys.exit(main())
