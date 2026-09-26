"""Build the quest POI badge textures (world-map quest areas and tracker rows).

Two outputs, both in the client's proven RLE TGA form:

- `media/questpoi.tga` -- `media/questpoi-v3.png` (main, hover and active
  circles, then the followed-quest glow, left to right, on a transparent
  background) reduced to a power-of-two 256x64 strip: one element per 64x64
  cell at x = 0, 64, 128 and 192. The three circles share one scale so their
  rims match; the glow is cropped to its own full fade.
- `media/QuestPOINumbers.tga` -- the numbers 1-25 in the same 8x8 grid as
  `UIQuestPOINumberIcons.tga`, at twice its definition (512x512, 64px cells). The glyph shapes are that atlas's plain black
  glyphs (rows 0-3), filled with a solid colour: rows 0-3 use the active
  colour #2c1501, rows 4-7 the main/hover colour #f8c662.

A source that is not present keeps its already-built TGA.

Run from the addon root:

    python tools/make_quest_poi_markers.py
"""

import os

from PIL import Image, ImageChops, ImageDraw

STRIP_SOURCE = os.path.join("media", "questpoi-v3.png")
STRIP_OUTPUT = os.path.join("media", "questpoi.tga")
GLYPH_SOURCE = os.path.join("media", "UIQuestPOINumberIcons.tga")
GLYPH_OUTPUT = os.path.join("media", "QuestPOINumbers.tga")

CELL = 64
ELEMENTS = 4
CIRCLES = 3
# Circles keep one texel of transparent margin inside their cell.
CIRCLE_FILL = 62.0 / CELL
# Alpha above which a pixel counts as part of an element, not stray noise.
ELEMENT_ALPHA = 16
GLOW_ALPHA = 2
GLYPH_CELL = 32
# The number atlas is drawn at twice the source's definition: 512x512, 64px
# cells. Texcoords are fractions of the atlas, so the layout is unchanged.
GLYPH_SCALE = 2
GLYPH_EDGE = (80, 176)
GLYPH_COUNT = 25
GLYPH_ROWS = 4
ACTIVE_RGB = (0x2C, 0x15, 0x01)
NORMAL_RGB = (0xF8, 0xC6, 0x62)


def write_tga_rle(image, path):
    image.save(path, format="TGA", compression="tga_rle")
    with open(path, "rb") as handle:
        header = handle.read(18)
    if len(header) != 18 or header[2] != 10 or header[16] != 32 or header[17] != 8:
        raise ValueError("RLE TGA writer did not produce the proven type-10 header")
    if Image.open(path).convert("RGBA").tobytes() != image.tobytes():
        raise ValueError("RLE encoding changed " + path)


def element_boxes(alpha):
    """Return each element's alpha bounding box, left to right."""
    mask = alpha.point(lambda value: 255 if value > ELEMENT_ALPHA else 0)
    columns = [x for x in range(mask.width)
               if mask.crop((x, 0, x + 1, mask.height)).getbbox()]
    runs = []
    for x in columns:
        if runs and x - runs[-1][1] <= 8:
            runs[-1][1] = x
        else:
            runs.append([x, x])
    runs = [run for run in runs if run[1] - run[0] > 32]
    if len(runs) != ELEMENTS:
        raise ValueError("expected %d elements, found %d" % (ELEMENTS, len(runs)))
    boxes = []
    for index, (left, right) in enumerate(runs):
        threshold = GLOW_ALPHA if index == CIRCLES else ELEMENT_ALPHA
        # The glow's faint fade reaches past its dense core, so it is measured
        # from the midpoint to its neighbours rather than from its core run.
        if index == CIRCLES:
            left = (runs[index - 1][1] + left) // 2
            right = alpha.width
        region = alpha.crop((left, 0, right + 1, alpha.height))
        box = region.point(lambda value, t=threshold: 255 if value > t else 0).getbbox()
        boxes.append((box[0] + left, box[1], box[2] + left, box[3]))
    return boxes


def square_crop(image, box, side):
    centre_x = (box[0] + box[2]) / 2.0
    centre_y = (box[1] + box[3]) / 2.0
    half = side / 2.0
    left = int(round(centre_x - half))
    top = int(round(centre_y - half))
    side = int(round(side))
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.paste(image.crop((left, top, left + side, top + side)), (0, 0))
    return canvas


def reduce(image):
    # Premultiplied resampling keeps the transparent edges from darkening.
    return image.convert("RGBa").resize((CELL, CELL), Image.LANCZOS).convert("RGBA")


def build_strip():
    source = Image.open(STRIP_SOURCE).convert("RGBA")
    boxes = element_boxes(source.getchannel("A"))
    circle_side = max(max(box[2] - box[0], box[3] - box[1])
                      for box in boxes[:CIRCLES]) / CIRCLE_FILL
    glow = boxes[CIRCLES]
    glow_side = max(glow[2] - glow[0], glow[3] - glow[1])
    output = Image.new("RGBA", (CELL * ELEMENTS, CELL), (0, 0, 0, 0))
    # Clears the source's faint stray pixels outside each circle's disc.
    disc = Image.new("L", (CELL, CELL), 0)
    ImageDraw.Draw(disc).ellipse((0, 0, CELL - 1, CELL - 1), fill=255)
    for index, box in enumerate(boxes):
        side = circle_side if index < CIRCLES else glow_side
        cell = reduce(square_crop(source, box, side))
        if index < CIRCLES:
            cell.putalpha(ImageChops.multiply(cell.getchannel("A"), disc))
        output.paste(cell, (index * CELL, 0))
    write_tga_rle(output, STRIP_OUTPUT)


def upscale_mask(mask):
    """Doubles a glyph's alpha mask with smooth edges rather than 2x2 blocks.

    A bicubic upscale rounds the source's stair-steps, and a steep ramp
    around the midpoint then re-sharpens the blurred edge to about one
    output texel of antialiasing, keeping the glyph's original weight.
    """
    size = (mask.width * GLYPH_SCALE, mask.height * GLYPH_SCALE)
    smooth = mask.resize(size, Image.BICUBIC)
    low, high = GLYPH_EDGE
    return smooth.point(lambda value: 0 if value <= low else 255 if value >= high
                        else (value - low) * 255 // (high - low))


def build_glyphs():
    source = Image.open(GLYPH_SOURCE).convert("RGBA")
    if source.size != (256, 256):
        raise ValueError("expected the 256x256 UIQuestPOINumberIcons atlas")
    cell = GLYPH_CELL * GLYPH_SCALE
    output = Image.new("RGBA", (256 * GLYPH_SCALE, 256 * GLYPH_SCALE), (0, 0, 0, 0))
    for number in range(1, GLYPH_COUNT + 1):
        index = number - 1
        column = index % 8
        row = index // 8
        box = (column * GLYPH_CELL, row * GLYPH_CELL,
               (column + 1) * GLYPH_CELL, (row + 1) * GLYPH_CELL)
        mask = upscale_mask(source.crop(box).getchannel("A"))
        for rgb, target_row in ((ACTIVE_RGB, row), (NORMAL_RGB, row + GLYPH_ROWS)):
            glyph = Image.new("RGBA", mask.size, rgb + (0,))
            glyph.putalpha(mask)
            output.paste(glyph, (column * cell, target_row * cell))
    write_tga_rle(output, GLYPH_OUTPUT)


def main():
    for source, build, output in ((STRIP_SOURCE, build_strip, STRIP_OUTPUT),
                                  (GLYPH_SOURCE, build_glyphs, GLYPH_OUTPUT)):
        if not os.path.exists(source):
            print("%s: kept, %s not found" % (output, source))
            continue
        build()
        print("%s: %d bytes" % (output, os.path.getsize(output)))


if __name__ == "__main__":
    main()
