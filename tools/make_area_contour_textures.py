"""Build the two quest-area contour profile strips used by UnrealQuest.

Map/AreaContours.lua colours every contour cell from the exact signed distance
between the cell centre and the quest's rounded hull (positive inside), in
units of one grid cell. A cell is only 1-2 screen pixels, so this per-pixel
coverage is what antialiases the edge; a marching-squares atlas minified about
forty-fold was point-sampled by the client into stair-steps with a dark
dotted rim.

Each strip is a 256x4 gradient: texel centre k holds the profile at distance
D_MIN + k/255 * (D_MAX - D_MIN), box-filtered over one cell width
(premultiplied), i.e. the average colour of a cell centred at that distance.
Texel 0 is transparent and texel 255 is the flat fill. A contour patch spans a
stretch of the strip across its width, so the bilinear filter evaluates the
profile per pixel.

The profile itself is ForeverFrameXML's quest blob: the outer glow uses the
exact colours and alpha ramp of `UI-QuestBlob-Outside`, the inside the fill
of `UI-QuestBlob-Inside`, with a short inner shadow between them. The neutral
strip keeps the same alpha profile in tintable colours.

The client drew an uncompressed type-2 atlas as diagonal corruption
(textures.uncompressed_512_tga_atlas_corrupts), while RLE type 10 with
descriptor 0x08 is the proven form (textures.rle_512_tga_atlas_four_arg_supported).

Run from the addon root:  python tools/make_area_contour_textures.py
"""

import math
import os

from PIL import Image

MEDIA = os.path.join(os.getcwd(), "media")

FOREVER_FILL_RGB = (57, 109, 255)
FOREVER_BORDER_RGB = (104, 187, 255)
FOREVER_FILL_ALPHA = 128
FOREVER_BORDER_ALPHA_SCALE = 192 / 255
FOREVER_BORDER_ALPHA_RAMP = (
    220, 198, 155, 113, 82, 53, 34, 16, 5, 0, 0, 0, 0, 0, 0, 0,
)
BORDER_WIDTH = 0.72
NEUTRAL_RGB = (255, 255, 255)
INNER_SHADOW_WIDTH = 0.44
FOREVER_SHADOW_RGB = (38, 47, 105)
FOREVER_SHADOW_ALPHA = 150
NEUTRAL_SHADOW_RGB = (92, 92, 92)

# Must match Map/AreaContours.lua.
PROFILE_SIZE = 256
PROFILE_HEIGHT = 4
# A cell further out than the glow plus half a cell has no colour at all; one
# further in than the shadow plus half a cell is flat fill.
PROFILE_D_MIN = -round(BORDER_WIDTH + 0.5, 2)
PROFILE_D_MAX = round(INNER_SHADOW_WIDTH + 0.5, 2)
BOX_SAMPLES = 64


def clamp(n, lo=0.0, hi=1.0):
    return max(lo, min(hi, n))


def forever_border_alpha(outside_distance):
    position = clamp(outside_distance / BORDER_WIDTH) * 15
    lower = int(math.floor(position))
    upper = min(15, lower + 1)
    amount = position - lower
    source_alpha = (FOREVER_BORDER_ALPHA_RAMP[lower] * (1 - amount)
                    + FOREVER_BORDER_ALPHA_RAMP[upper] * amount)
    return source_alpha * FOREVER_BORDER_ALPHA_SCALE


def smoothstep(value):
    value = clamp(value)
    return value * value * (3 - 2 * value)


def interpolate(a, b, amount):
    return int(round(a + (b - a) * amount))


def profile(d, border_rgb, shadow_rgb, fill_rgb):
    """The quest-blob colour and alpha at signed distance d (cells, + inside)."""
    if d < 0:
        alpha = forever_border_alpha(-d)
        if alpha > 0:
            return border_rgb, alpha
        return (0, 0, 0), 0
    if d < INNER_SHADOW_WIDTH:
        amount = smoothstep(d / INNER_SHADOW_WIDTH)
        rgb = tuple(interpolate(shadow_rgb[index], fill_rgb[index], amount)
                    for index in range(3))
        return rgb, interpolate(FOREVER_SHADOW_ALPHA, FOREVER_FILL_ALPHA, amount)
    return fill_rgb, FOREVER_FILL_ALPHA


def texel_distance(texel):
    return PROFILE_D_MIN + (PROFILE_D_MAX - PROFILE_D_MIN) * texel / (PROFILE_SIZE - 1)


def box_filtered(d, profile_fn):
    """Premultiplied average of the profile over one cell centred at d."""
    total = [0.0, 0.0, 0.0, 0.0]
    for index in range(BOX_SAMPLES):
        rgb, alpha = profile_fn(d - 0.5 + (index + 0.5) / BOX_SAMPLES)
        weight = alpha / 255
        for n in range(3):
            total[n] += rgb[n] * weight
        total[3] += weight
    if total[3] <= 0:
        return (0, 0, 0, 0)
    colour = tuple(int(round(total[n] / total[3])) for n in range(3))
    return colour + (int(round(total[3] / BOX_SAMPLES * 255)),)


def build_profile(profile_fn):
    values = [box_filtered(texel_distance(texel), profile_fn)
              for texel in range(PROFILE_SIZE)]
    # A transparent texel keeps the colour of the nearest visible one, so
    # filtering towards it fades the glow out instead of darkening it.
    first = next(index for index, value in enumerate(values) if value[3] > 0)
    for index in range(first):
        values[index] = values[first][:3] + (0,)
    image = Image.new("RGBA", (PROFILE_SIZE, PROFILE_HEIGHT))
    pixels = image.load()
    for texel, value in enumerate(values):
        for row in range(PROFILE_HEIGHT):
            pixels[texel, row] = value
    return image

def write_tga_rle(image, path):
    image = image.convert("RGBA")
    image.save(path, format="TGA", compression="tga_rle")
    with open(path, "rb") as handle:
        header = handle.read(18)
    if len(header) != 18 or header[2] != 10 or header[16] != 32 or header[17] != 8:
        raise ValueError("RLE TGA writer did not produce the proven type-10 header")
    return os.path.getsize(path)


def main():
    strips = (
        ("AreaContourProfile.tga",
         lambda d: profile(d, FOREVER_BORDER_RGB, FOREVER_SHADOW_RGB, FOREVER_FILL_RGB)),
        ("AreaContourProfileNeutral.tga",
         lambda d: profile(d, NEUTRAL_RGB, NEUTRAL_SHADOW_RGB, NEUTRAL_RGB)),
    )
    for filename, profile_fn in strips:
        path = os.path.join(MEDIA, filename)
        strip = build_profile(profile_fn)
        size = write_tga_rle(strip, path)
        if Image.open(path).convert("RGBA").tobytes() != strip.tobytes():
            raise ValueError("RLE encoding changed generated strip " + filename)
        print("%s: %d bytes" % (filename, size))


if __name__ == "__main__":
    main()
