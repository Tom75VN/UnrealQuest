"""Build the reward tile plates for the dialogue's rewards panel.

UQ_Parchment_Reward_Tile          from UQ_Choice_Normal: an item's framed plate
UQ_Parchment_Reward_Tile_Selected from UQ_Choice_Selected: the picked choice

The sources are 1024x256 uncompressed TGAs, the form that corrupts on this
client (textures.uncompressed_512_tga_atlas_corrupts). Each plate is cropped
to its drawn bounds and rebuilt as a 128x64 three-slice strip: a 32px left
cap, a 64px stretchable centre and a 32px right cap, so the gold corners keep
their shape at any tile width (Client.CreateQuestDialogueTurnIn draws the
three parts with SetTexCoord 0-0.25, 0.25-0.75, 0.75-1). Written as 32-bit
RLE TGA type 10 with descriptor 0x08, like every addon TGA here.

Run from the addon root:  python tools/make_reward_tile.py
"""

import os

from PIL import Image

FOLDER = os.path.join(os.getcwd(), "media", "Textures", "Dialogues", "Parchment")
HEIGHT = 64
CAP = 32
CENTRE = 64


def write_tga_rle(image, path):
    image = image.convert("RGBA")
    image.save(path, format="TGA", compression="tga_rle")
    with open(path, "rb") as handle:
        header = handle.read(18)
    if len(header) != 18 or header[2] != 10 or header[16] != 32 or header[17] != 8:
        raise ValueError("RLE TGA writer did not produce the proven type-10 header")
    return os.path.getsize(path)


def plate(source):
    image = Image.open(os.path.join(FOLDER, source + ".tga")).convert("RGBA")
    box = image.getchannel("A").point(lambda a: 255 if a > 40 else 0).getbbox()
    crop = image.crop(box)
    width, height = crop.size
    scale = HEIGHT / float(height)
    cap = int(round(CAP / scale))
    left = crop.crop((0, 0, cap, height)).resize((CAP, HEIGHT), Image.LANCZOS)
    right = crop.crop((width - cap, 0, width, height)).resize((CAP, HEIGHT), Image.LANCZOS)
    middle = crop.crop((cap, 0, width - cap, height)).resize((CENTRE, HEIGHT), Image.LANCZOS)
    strip = Image.new("RGBA", (2 * CAP + CENTRE, HEIGHT), (0, 0, 0, 0))
    strip.paste(left, (0, 0))
    strip.paste(middle, (CAP, 0))
    strip.paste(right, (CAP + CENTRE, 0))
    return strip


def main():
    for name, source in (("UQ_Parchment_Reward_Tile", "UQ_Choice_Normal"),
                         ("UQ_Parchment_Reward_Tile_Selected", "UQ_Choice_Selected")):
        path = os.path.join(FOLDER, name + ".tga")
        print("%-30s %8d bytes" % (name + ".tga", write_tga_rle(plate(source), path)))


if __name__ == "__main__":
    main()
