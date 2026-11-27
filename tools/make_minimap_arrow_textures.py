"""Build the minimap follow arrow: the gold guard arrow in 64 rotated frames.

Run from the addon folder: python tools/make_minimap_arrow_textures.py

The arrow sits on the minimap rim and points at the followed quest's nearest
point when that point is outside the minimap view (Map/MinimapPins.lua).

Source: tools/art/MinimapFollowArrowSource.tga, a copy of the gold minimap
guard arrow sheet (user choice, 2026-11-27): 512x512, an 8x8 grid of 64x64
cells, frame 0 pointing up and the angle increasing counter-clockwise, one
frame every 5.625 degrees -- already the addon's bearing convention, so the
frames are taken in order, never re-rotated.

The output repeats the navigator arrow's container exactly
(tools/make_navigator_textures.py): four 512x512 RLE type-10 TGAs, each a 4x4
grid of 128x128 cells. That form is the one confirmed to draw on this client;
the source's own 8x8 layout is not. A smaller 256x512 atlas is recorded as
drawing its cells shifted (textures.minimap_mail_256x512_atlas_settexcoord_travels),
and the eight-value rotated SetTexCoord is ignored
(textures.settexcoord_rotated_8_value_form_ignored), so rotation stays baked.
Each 64px source cell is scaled 2x into its 128px cell, so a cell's framing
(and FOLLOW_ARROW_SIZE's meaning) is unchanged.
"""

import os

from PIL import Image

SOURCE = os.path.join(os.getcwd(), "tools", "art", "MinimapFollowArrowSource.tga")
OUT_DIR = os.path.join(os.getcwd(), "media", "Textures", "Map", "Pins")
PREFIX = "MinimapFollowArrowFrames"

FRAMES = 64
ATLASES = 4
FRAMES_PER_ATLAS = 16
COLUMNS = 4
CELL = 128
SOURCE_COLUMNS = 8
SOURCE_CELL = 64


def build_atlases():
    source = Image.open(SOURCE).convert("RGBA")
    if source.size != (SOURCE_COLUMNS * SOURCE_CELL, SOURCE_COLUMNS * SOURCE_CELL):
        raise ValueError("unexpected source sheet size %r" % (source.size,))
    atlases = [Image.new("RGBA", (512, 512), (0, 0, 0, 0)) for _ in range(ATLASES)]
    for frame in range(FRAMES):
        sx = (frame % SOURCE_COLUMNS) * SOURCE_CELL
        sy = (frame // SOURCE_COLUMNS) * SOURCE_CELL
        cell = source.crop((sx, sy, sx + SOURCE_CELL, sy + SOURCE_CELL))
        cell = cell.resize((CELL, CELL), Image.LANCZOS)
        atlas = frame // FRAMES_PER_ATLAS
        local = frame % FRAMES_PER_ATLAS
        column = local % COLUMNS
        row = local // COLUMNS
        atlases[atlas].paste(cell, (column * CELL, row * CELL))
    return atlases


def write_tga_rle(image, path):
    image.convert("RGBA").save(path, format="TGA", compression="tga_rle")
    with open(path, "rb") as handle:
        header = handle.read(18)
    if len(header) != 18 or header[2] != 10 or header[16] != 32 or header[17] != 8:
        raise ValueError("RLE TGA writer did not produce the proven type-10 header")
    return os.path.getsize(path)


for index, atlas in enumerate(build_atlases()):
    name = "%s%d.tga" % (PREFIX, index)
    size = write_tga_rle(atlas, os.path.join(OUT_DIR, name))
    print("%s 512x512 %d bytes" % (name, size))
