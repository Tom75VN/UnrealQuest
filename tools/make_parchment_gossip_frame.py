"""Build the Parchment theme's gossip row frame from its own card art.

Source: media/Textures/Dialogues/Parchment/UQ_Dialogue_9Slice_Master.tga, the
card master. Its top-left gold corner bracket is cut out by flood-filling the
bright metal from inside it: the bracket's dark outline stops the fill before
the parchment, so only the metal is kept (the mask grown back over that
outline and feathered).
Output: media/Textures/Dialogues/Parchment/UQ_Parchment_Gossip_Frame.tga
(512x128), a slim gold frame with an empty middle: a bevelled gold rule along
each edge, shaded from the bracket's own colours, and the bracket mirrored
into all four corners. The row's dark fill shows through the middle.

The row draws it as a three-part plate (Client.SkinQuestDialoguePlate): caps
CAP px of the width at each end, the rule between them stretched. Each cap is
CAP/HEIGHT of the row's height wide, so a bracket keeps its shape at any row
width; Client.QUEST_DIALOGUE_CARD.GOSSIP_FRAME carries both ratios.

Written as 32-bit RLE TGA type 10 with descriptor 0x08, the proven form
(textures.rle_512_tga_atlas_four_arg_supported).

Run from the addon root:  python tools/make_parchment_gossip_frame.py
"""

import os
from collections import deque

from PIL import Image, ImageChops, ImageDraw, ImageFilter

FOLDER = os.path.join(os.getcwd(), "media", "Textures", "Dialogues", "Parchment")
SOURCE = "UQ_Dialogue_9Slice_Master.tga"
TARGET = "UQ_Parchment_Gossip_Frame.tga"

WIDTH, HEIGHT = 512, 128
# Cap width in texture pixels: one row height, so CAP_U 0.25, cap share 1.
CAP = 128
# The master's corner region, a pixel inside the bracket's metal, and the
# brightness the fill stays above.
CORNER = 230
SEED = (100, 100)
BRIGHT = 0.3
# Bracket size in the frame, and the rule: its inset from the frame's edge
# and its thickness.
BRACKET = 60
RULE_INSET = 9
RULE = 6
# Bevel shading across the rule, outer edge to inner edge, from the
# bracket's dark rim, mid gold and highlight.
RULE_SHADES = ((60, 38, 10), (168, 115, 49), (255, 222, 140), (210, 150, 60),
               (140, 92, 26), (50, 32, 8))


def cut_bracket():
    master = Image.open(os.path.join(FOLDER, SOURCE)).convert("RGBA")
    corner = master.crop((0, 0, CORNER, CORNER))
    pixels = corner.load()
    seen = set([SEED])
    queue = deque([SEED])
    while queue:
        x, y = queue.popleft()
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nx, ny = x + dx, y + dy
            if 0 <= nx < CORNER and 0 <= ny < CORNER and (nx, ny) not in seen:
                r, g, b, a = pixels[nx, ny]
                if a > 128 and max(r, g, b) / 255.0 > BRIGHT:
                    seen.add((nx, ny))
                    queue.append((nx, ny))
    if max(p[0] for p in seen) >= CORNER - 1 or max(p[1] for p in seen) >= CORNER - 1:
        raise ValueError("bracket fill leaked into the parchment")
    mask = Image.new("L", corner.size, 0)
    mask_pixels = mask.load()
    for point in seen:
        mask_pixels[point] = 255
    mask = (mask.filter(ImageFilter.MaxFilter(5)).filter(ImageFilter.MinFilter(3))
            .filter(ImageFilter.MaxFilter(3)).filter(ImageFilter.GaussianBlur(0.8)))
    bracket = corner.copy()
    bracket.putalpha(ImageChops.multiply(corner.getchannel("A"), mask))
    bracket = bracket.crop(bracket.getchannel("A").point(lambda v: 255 if v > 8 else 0).getbbox())
    return bracket.resize((BRACKET, BRACKET), Image.LANCZOS)


def draw_rules(frame):
    draw = ImageDraw.Draw(frame)
    for index, shade in enumerate(RULE_SHADES):
        offset = RULE_INSET + index
        colour = shade + (255,)
        draw.line((offset, offset, WIDTH - 1 - offset, offset), fill=colour)
        draw.line((offset, HEIGHT - 1 - offset, WIDTH - 1 - offset, HEIGHT - 1 - offset),
                  fill=colour)
        draw.line((offset, offset, offset, HEIGHT - 1 - offset), fill=colour)
        draw.line((WIDTH - 1 - offset, offset, WIDTH - 1 - offset, HEIGHT - 1 - offset),
                  fill=colour)


def write_tga_rle(image, path):
    image.convert("RGBA").save(path, format="TGA", compression="tga_rle")
    with open(path, "rb") as handle:
        header = handle.read(18)
    if len(header) != 18 or header[2] != 10 or header[16] != 32 or header[17] != 8:
        raise ValueError("RLE TGA writer did not produce the proven type-10 header")
    return os.path.getsize(path)


def main():
    bracket = cut_bracket()
    frame = Image.new("RGBA", (WIDTH, HEIGHT), (0, 0, 0, 0))
    draw_rules(frame)
    flipped = bracket.transpose(Image.FLIP_LEFT_RIGHT)
    frame.alpha_composite(bracket, (0, 0))
    frame.alpha_composite(flipped, (WIDTH - BRACKET, 0))
    frame.alpha_composite(bracket.transpose(Image.FLIP_TOP_BOTTOM), (0, HEIGHT - BRACKET))
    frame.alpha_composite(flipped.transpose(Image.FLIP_TOP_BOTTOM),
                          (WIDTH - BRACKET, HEIGHT - BRACKET))
    path = os.path.join(FOLDER, TARGET)
    print("%s %dx%d %d bytes" % (TARGET, WIDTH, HEIGHT, write_tga_rle(frame, path)))


if __name__ == "__main__":
    main()
