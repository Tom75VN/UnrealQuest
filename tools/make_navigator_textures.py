"""Build the navigator textures in the TGA form this client actually renders.

Two measured constraints shape this, both from
textures.addon_tga_paths_require_extensionless and existing working files:

  * 32-bit BGRA with bottom-up row order and descriptor 0x08,
  * dimensions need NOT be powers of two -- ActiveQuestIcon.tga is 19x32 and
    renders, so the canvas is sized for the job rather than padded to 512.

The arrow is 64 frames split across four 4x4 atlases. The client accepts the documented
eight-argument SetTexCoord call but visibly distorts the image while the UV
corners leave 0..1, so rotation is baked here and the addon selects a frame
with the proven four-argument form instead. Each cell is square and the arrow
fits its inscribed circle, so every frame has the same scale and clips nothing.
Each 512x512 atlas is RLE-compressed TGA type 10, matching pfQuest's proven
512x512 arrow atlas. The live client drew the first atlas as diagonal corruption
when it was the 1 MiB uncompressed type 2 form; the smaller static arc remains
type 2 because that exact form is already confirmed visible.
"""

import math
import os
import struct

from PIL import Image

MEDIA = os.path.join(os.getcwd(), "media")


def write_tga(image, path):
    image = image.convert("RGBA")
    width, height = image.size
    # Descriptor 0x08: 8 alpha bits, origin bottom-left -- so the first row in
    # the file is the BOTTOM row of the image.
    header = struct.pack(
        "<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, width, height, 32, 0x08)
    flipped = image.transpose(Image.FLIP_TOP_BOTTOM)
    pixels = flipped.tobytes()
    out = bytearray(len(pixels))
    out[0::4] = pixels[2::4]   # B
    out[1::4] = pixels[1::4]   # G
    out[2::4] = pixels[0::4]   # R
    out[3::4] = pixels[3::4]   # A
    with open(path, "wb") as handle:
        handle.write(header)
        handle.write(bytes(out))
    return width, height, len(header) + len(out)


def write_tga_rle(image, path):
    image = image.convert("RGBA")
    # Pillow writes the same relevant header contract as pfQuest's working
    # arrow.tga: image type 10, 32bpp, descriptor 0x08, bottom-left origin.
    image.save(path, format="TGA", compression="tga_rle")
    with open(path, "rb") as handle:
        header = handle.read(18)
    if len(header) != 18 or header[2] != 10 or header[16] != 32 or header[17] != 8:
        raise ValueError("RLE TGA writer did not produce the proven type-10 header")
    return image.size[0], image.size[1], os.path.getsize(path)


ARROW_FRAMES = 64
ARROW_ATLASES = 4
ARROW_FRAMES_PER_ATLAS = 16
ARROW_COLUMNS = 4
ARROW_CELL = 128
ARROW_WORK_CANVAS = 512


def build_arrow_base(canvas=ARROW_WORK_CANVAS):
    source = Image.open(os.path.join(MEDIA, "NavigationArrow.png")).convert("RGBA")
    box = source.getchannel("A").getbbox()
    source = source.crop(box)
    width, height = source.size

    # Fit the content's bounding circle inside the canvas's inscribed circle,
    # with two pixels to spare, so a full turn never clips a corner.
    radius = math.sqrt((width * 0.5) ** 2 + (height * 0.5) ** 2)
    scale = (canvas * 0.5 - 2.0) / radius
    scaled = source.resize(
        (max(1, int(round(width * scale))), max(1, int(round(height * scale)))),
        Image.LANCZOS)

    out = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    out.paste(scaled,
              ((canvas - scaled.size[0]) // 2, (canvas - scaled.size[1]) // 2))
    return out, scaled.size


def build_arrow_atlases():
    base, inner = build_arrow_base()
    atlases = [Image.new("RGBA", (512, 512), (0, 0, 0, 0))
               for _ in range(ARROW_ATLASES)]
    for frame in range(ARROW_FRAMES):
        # Pillow's positive angle is counter-clockwise, matching the addon's
        # positive relative angle: a quest to the player's left is positive.
        angle = 360.0 * frame / ARROW_FRAMES
        rotated = base.rotate(angle, resample=Image.BICUBIC, expand=False)
        cell = rotated.resize((ARROW_CELL, ARROW_CELL), Image.LANCZOS)
        atlas_index = frame // ARROW_FRAMES_PER_ATLAS
        local_frame = frame % ARROW_FRAMES_PER_ATLAS
        column = local_frame % ARROW_COLUMNS
        row = local_frame // ARROW_COLUMNS
        atlases[atlas_index].paste(
            cell, (column * ARROW_CELL, row * ARROW_CELL))
    return atlases, inner


def build_arc(target_width=512):
    source = Image.open(os.path.join(MEDIA, "NavigationArc.png")).convert("RGBA")
    width, height = source.size
    scale = float(target_width) / width
    # Static: never rotated, so it needs neither a square canvas nor margin.
    return source.resize(
        (target_width, max(1, int(round(height * scale)))), Image.LANCZOS)


arrows, inner = build_arrow_atlases()
print("arrow source content %dx%d; 64 frames across %d atlases"
      % (inner[0], inner[1], len(arrows)))
for atlas_index, arrow in enumerate(arrows):
    name = "NavigationArrowFrames%d.tga" % atlas_index
    print("%s %dx%d %d bytes" % ((name,) + write_tga_rle(
        arrow, os.path.join(MEDIA, name))))

arc = build_arc()
print("NavigationArc.tga %dx%d %d bytes"
      % write_tga(arc, os.path.join(MEDIA, "NavigationArc.tga")))
