"""Cut the quest dialogue's parchment frame into nine slices.

Source: media/Textures/Dialogues/Parchment/UQ_Dialogue_9Slice_Master.png (1774x887),
the authored parchment with its torn edge and four gold corner brackets. The
brackets end about 185 px in from each image edge, so a 200 px grid keeps
every bracket whole inside its corner slice:

    TL | T | TR      corners: 200x200, drawn at a fixed size
    L  | C | R       T/B: stretched horizontally, L/R vertically
    BL | B | BR      C:   stretched both ways

Every slice is cut from the same grid of the same image, so neighbouring
slices meet on identical pixels. Each is resampled to a power-of-two size
and written as 32-bit RLE TGA type 10 with descriptor 0x08: the client drew
an uncompressed 512x512 TGA as diagonal bands
(textures.uncompressed_512_tga_atlas_corrupts), and the RLE form is the
proven one (textures.rle_512_tga_atlas_four_arg_supported).

Compatibility/ClientAPI.lua (Client.QUEST_DIALOGUE_CARD) is sized from SOURCE_EDGE;
change them together.

Run from the addon root:  python tools/make_dialogue_slices.py
"""

import os

from PIL import Image

FOLDER = os.path.join(os.getcwd(), "media", "Textures", "Dialogues", "Parchment")
SOURCE = "UQ_Dialogue_9Slice_Master.png"

# Source pixels from each image edge to the slice grid line.
SOURCE_EDGE = 200

# name, output size (power of two), and the crop box relative to the grid.
SLICES = (
    ("TL", (128, 128), lambda w, h, e: (0, 0, e, e)),
    ("T", (512, 64), lambda w, h, e: (e, 0, w - e, e)),
    ("TR", (128, 128), lambda w, h, e: (w - e, 0, w, e)),
    ("L", (64, 256), lambda w, h, e: (0, e, e, h - e)),
    ("C", (512, 256), lambda w, h, e: (e, e, w - e, h - e)),
    ("R", (64, 256), lambda w, h, e: (w - e, e, w, h - e)),
    ("BL", (128, 128), lambda w, h, e: (0, h - e, e, h)),
    ("B", (512, 64), lambda w, h, e: (e, h - e, w - e, h)),
    ("BR", (128, 128), lambda w, h, e: (w - e, h - e, w, h)),
)


def write_tga_rle(image, path):
    image = image.convert("RGBA")
    image.save(path, format="TGA", compression="tga_rle")
    with open(path, "rb") as handle:
        header = handle.read(18)
    if len(header) != 18 or header[2] != 10 or header[16] != 32 or header[17] != 8:
        raise ValueError("RLE TGA writer did not produce the proven type-10 header")
    return os.path.getsize(path)


def main():
    source = Image.open(os.path.join(FOLDER, SOURCE)).convert("RGBA")
    width, height = source.size
    for name, size, box in SLICES:
        piece = source.crop(box(width, height, SOURCE_EDGE))
        piece = piece.resize(size, Image.LANCZOS)
        path = os.path.join(FOLDER, "UQ_Parchment_Slice_" + name + ".tga")
        print("%-28s %4dx%-4d %8d bytes" % (os.path.basename(path), size[0],
                                             size[1], write_tga_rle(piece, path)))


if __name__ == "__main__":
    main()
