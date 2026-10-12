"""Cut the classic dialogue's divider into pieces that never deform.

Source: media/Textures/Dialogues/Parchment/UQ_Divider.tga (1024x128, kept as delivered).
Output: media/Textures/Dialogues/Parchment/UQ_Parchment_Divider_CapL.tga, UQ_Parchment_Divider_Line.tga,
        UQ_Parchment_Divider_CapR.tga

The source is a thin rule with an ornate end cap on each side. Drawn whole at
any width other than its own it stretches the caps, and 1024 px is above the
512 px no texture here is proven past. So it is cut into three 64x32 tiles at
the source's own scale, no resampling: the two caps (x 16..80 and 944..1008,
each with the start of the rule) and a run of plain rule (x 200..264, the same
in every column). Every tile spans y 48..80, the opaque band (y 54..74) with
a little margin. Client.LayQuestDialogueDivider draws the caps at their own
2:1 aspect and stretches only the rule between them.

Every output is 32-bit RLE TGA type 10, like every other large addon TGA here
(textures.uncompressed_512_tga_atlas_corrupts).
"""

import os

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
FOLDER = os.path.join(HERE, "..", "media", "Textures", "Dialogues", "Parchment")
TOP, BOTTOM = 48, 80
PIECES = {
    "UQ_Parchment_Divider_CapL": 16,
    "UQ_Parchment_Divider_Line": 200,
    "UQ_Parchment_Divider_CapR": 944,
}


def main():
    source = Image.open(os.path.join(FOLDER, "UQ_Divider.tga")).convert("RGBA")
    for name, left in PIECES.items():
        piece = source.crop((left, TOP, left + 64, BOTTOM))
        path = os.path.join(FOLDER, name + ".tga")
        piece.save(path, format="TGA", compression="tga_rle")
        with open(path, "rb") as handle:
            if handle.read(3)[2] != 10:
                raise ValueError("RLE TGA writer did not produce a type-10 header")
        print(name, piece.size)


if __name__ == "__main__":
    main()
