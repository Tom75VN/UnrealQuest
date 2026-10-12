"""Draw the quest dialogue's two requirement status icons.

UQ_Dialogue_StatusDone     a green disc with a white check: the item is in hand
UQ_Dialogue_StatusMissing  a red disc with a white cross: the item is short

No stock check-mark texture has a record on this client, so the addon draws
its own. Each icon is drawn at 8x and box-downsampled to 64x64 for clean
antialiased edges, with a dark rim so it reads on parchment and on dark art.
Written as 32-bit RLE TGA type 10 with descriptor 0x08, the form every addon
TGA here uses (textures.uncompressed_512_tga_atlas_corrupts). The basenames
are unique across the addon (textures.addon_paths_resolved_by_basename).

Run from the addon root:  python tools/make_dialogue_status_icons.py
"""

import os

from PIL import Image, ImageDraw

FOLDER = os.path.join(os.getcwd(), "media", "Textures", "Dialogues")
SIZE = 64
SCALE = 8

DONE_FILL = (46, 140, 38, 255)
MISSING_FILL = (176, 38, 22, 255)
RIM = (40, 22, 8, 255)
MARK = (255, 250, 236, 255)


def write_tga_rle(image, path):
    image = image.convert("RGBA")
    image.save(path, format="TGA", compression="tga_rle")
    with open(path, "rb") as handle:
        header = handle.read(18)
    if len(header) != 18 or header[2] != 10 or header[16] != 32 or header[17] != 8:
        raise ValueError("RLE TGA writer did not produce the proven type-10 header")
    return os.path.getsize(path)


def disc(fill):
    big = SIZE * SCALE
    image = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    inset = 3 * SCALE
    draw.ellipse((inset, inset, big - inset, big - inset), fill=RIM)
    rim = 7 * SCALE
    draw.ellipse((rim, rim, big - rim, big - rim), fill=fill)
    return image, draw, big


def check():
    image, draw, big = disc(DONE_FILL)
    width = 7 * SCALE
    points = [(0.28 * big, 0.52 * big), (0.44 * big, 0.68 * big),
              (0.73 * big, 0.36 * big)]
    draw.line(points, fill=MARK, width=width, joint="curve")
    for x, y in (points[0], points[2]):
        r = width / 2
        draw.ellipse((x - r, y - r, x + r, y + r), fill=MARK)
    return image.resize((SIZE, SIZE), Image.BOX)


def cross():
    image, draw, big = disc(MISSING_FILL)
    width = 7 * SCALE
    a, b = 0.34 * big, 0.66 * big
    for start, end in (((a, a), (b, b)), ((a, b), (b, a))):
        draw.line((start, end), fill=MARK, width=width)
        for x, y in (start, end):
            r = width / 2
            draw.ellipse((x - r, y - r, x + r, y + r), fill=MARK)
    return image.resize((SIZE, SIZE), Image.BOX)


def main():
    for name, build in (("UQ_Dialogue_StatusDone", check),
                        ("UQ_Dialogue_StatusMissing", cross)):
        image = build()
        image.save(os.path.join(FOLDER, name + ".png"))
        path = os.path.join(FOLDER, name + ".tga")
        print("%-32s %8d bytes" % (name + ".tga", write_tga_rle(image, path)))


if __name__ == "__main__":
    main()
