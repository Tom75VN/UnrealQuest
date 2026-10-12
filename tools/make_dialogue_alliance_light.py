"""Build the Alliance light dialogue theme from the geometry-locked Horde light set.

The two generated PNGs in ``media/Textures/Dialogues/#src/AllianceLight`` are style
masters. Runtime geometry and alpha come from the proven Cinematic TGAs, so
every output keeps the same size, slicing, and transparent silhouette.

Run from the addon root:  python tools/make_dialogue_alliance_light.py
"""

import colorsys
import os

from PIL import Image, ImageEnhance

import make_dialogue_horde_light as cinematic
import mend_dialogue_rail


ROOT = os.getcwd()
DIALOGUES = os.path.join(ROOT, "media", "Textures", "Dialogues")
SOURCE = os.path.join(DIALOGUES, "HordeLight")
STYLE = os.path.join(DIALOGUES, "#src", "AllianceLight")
OUTPUT = os.path.join(DIALOGUES, "AllianceLight")

FRAME_STYLE = os.path.join(STYLE, "Alliance_Frame.png")
HEADER_STYLE = os.path.join(STYLE, "Alliance_Blue_Header_Smooth.png")
PANEL_STYLE = os.path.join(STYLE, "Alliance_Blue_Panel.png")
REWARD_STYLE = os.path.join(STYLE, "Alliance_Reward_Plate.png")
REWARD_SELECTED_STYLE = os.path.join(STYLE, "Alliance_Reward_Plate_Selected.png")


def rgba(path):
    return Image.open(path).convert("RGBA")


def pixels(image):
    if hasattr(image, "get_flattened_data"):
        return image.get_flattened_data()
    return image.getdata()


def median(values, fallback):
    if not values:
        return fallback
    values.sort()
    return values[len(values) // 2]


def style_palette():
    """Read the generated master instead of baking an unrelated palette."""
    image = rgba(FRAME_STYLE)
    blue = []
    gold = []
    silver = []
    for red, green, blue_value, alpha in pixels(image):
        if alpha < 180:
            continue
        maximum = max(red, green, blue_value)
        minimum = min(red, green, blue_value)
        if blue_value > red * 1.35 and blue_value > green * 1.12 and maximum > 80:
            blue.append((red, green, blue_value))
        elif red > green * 1.12 and green > blue_value * 1.35 and maximum > 100:
            gold.append((red, green, blue_value))
        elif maximum - minimum < 35 and maximum > 135:
            silver.append((red, green, blue_value))

    def channel(rows, index, fallback):
        return median([row[index] for row in rows], fallback)

    return {
        "blue": tuple(channel(blue, index, fallback)
                      for index, fallback in enumerate((18, 62, 158))),
        "gold": tuple(channel(gold, index, fallback)
                      for index, fallback in enumerate((221, 168, 54))),
        "silver": tuple(channel(silver, index, fallback)
                        for index, fallback in enumerate((196, 205, 216))),
    }


PALETTE = style_palette()


def mix(first, second, amount):
    return tuple(int(round(first[index] * (1 - amount) + second[index] * amount))
                 for index in range(3))


def is_true_red(red, green, blue):
    """Match saturated Horde-red gems without catching bronze or brown wear."""
    return (red > 135 and green < red * 0.45 and blue < red * 0.40 and
            red - green > 75 and red - blue > 80)


def alliance_pixel(pixel):
    red, green, blue, alpha = pixel
    if alpha == 0:
        return pixel
    hue, saturation, value = colorsys.rgb_to_hsv(red / 255.0, green / 255.0,
                                                  blue / 255.0)

    # Red gems are the clearest Horde cue. They become saturated sapphires.
    if is_true_red(red, green, blue):
        shade = 0.45 + value * 0.75
        target = tuple(min(255, int(channel * shade)) for channel in PALETTE["blue"])
        return target + (alpha,)

    # The reading surface is already authored parchment. Keep its light tones
    # intact; recolouring warm stains caused the blue speckling seen in game.
    if value > 0.78:
        return pixel

    # Bronze rails and dark wood become bright steel, blue enamel, and gold edges.
    warm = hue < 0.16 or hue > 0.97
    if warm and saturation > 0.28:
        silver = mix(PALETTE["silver"], (224, 232, 242), 0.72)
        gold = mix(PALETTE["gold"], (238, 187, 66), 0.62)
        if value > 0.58:
            target = mix(gold, (255, 239, 177), (value - 0.58) / 0.42)
        elif value > 0.20:
            target = mix((64, 78, 108), silver, (value - 0.20) / 0.38)
        else:
            target = mix((7, 20, 52), PALETTE["blue"], value / 0.20)
        return target + (alpha,)

    # Cool the parchment slightly without making the reading surface blue.
    if value > 0.45 and saturation < 0.34:
        target = mix((red, green, blue), (226, 224, 211), 0.10)
        return target + (alpha,)
    return (red, green, blue, alpha)


def recolor(image):
    output = Image.new("RGBA", image.size, (0, 0, 0, 0))
    output.putdata([alliance_pixel(pixel) for pixel in pixels(image)])
    return output


def recolor_gems(image):
    output = Image.new("RGBA", image.size, (0, 0, 0, 0))
    converted = []
    for pixel in pixels(image):
        red, green, blue, alpha = pixel
        if is_true_red(red, green, blue):
            converted.append(alliance_pixel(pixel))
        else:
            converted.append(pixel)
    output.putdata(converted)
    return output


def alliance_frame(geometry):
    """Use the authored V2 Alliance frame, clipped to proven frame geometry."""
    frame = rgba(FRAME_STYLE)
    if frame.size != geometry.size:
        frame = frame.resize(geometry.size, Image.LANCZOS)
    # The V2 master supplies every visible colour; the established alpha is
    # retained exactly so the old client receives the same proven silhouette.
    frame.putalpha(geometry.getchannel("A"))
    return frame


def fit_blue_panel(path, size, alpha):
    panel = rgba(path)
    bounds = panel.getchannel("A").point(lambda value: 255 if value > 20 else 0).getbbox()
    if bounds:
        panel = panel.crop(bounds)
    panel = ImageEnhance.Contrast(panel).enhance(1.08)
    panel = panel.resize(size, Image.LANCZOS)
    panel.putalpha(alpha)
    return panel


def blue_panel(size, alpha):
    return fit_blue_panel(PANEL_STYLE, size, alpha)


def blue_header(size, alpha):
    return fit_blue_panel(HEADER_STYLE, size, alpha)


def reward_plate(geometry, path):
    return rgba(path).resize(geometry.size, Image.LANCZOS)


def scenic_grade(image):
    alpha = image.getchannel("A")
    rgb = ImageEnhance.Color(image.convert("RGB")).enhance(0.92)
    blue = Image.new("RGB", image.size, (32, 60, 112))
    rgb = Image.blend(rgb, blue, 0.08)
    rgb = ImageEnhance.Contrast(rgb).enhance(1.04)
    rgb.putalpha(alpha)
    return rgb


def write_tga(image, path):
    image.convert("RGBA").save(path, format="TGA", compression="tga_rle")
    with open(path, "rb") as handle:
        header = handle.read(18)
    if len(header) != 18 or header[2] != 10 or header[16] != 32 or header[17] != 8:
        raise ValueError("Alliance texture is not a 32-bit RLE type-10 TGA: " + path)


def write_cards():
    original_load = cinematic.load

    def styled_load(name):
        image = original_load(name)
        if name == cinematic.FRAME:
            return alliance_frame(image)
        if name == cinematic.PLANK:
            return blue_header(image.size, image.getchannel("A"))
        return image

    cinematic.load = styled_load
    try:
        cards = (
            ("Card_", cinematic.BODY_CUT, cinematic.compose_card()),
            ("CardTall_", cinematic.BODY_CUT_TALL,
             cinematic.compose_card(cinematic.BODY_CUT_TALL)),
        )
    finally:
        cinematic.load = original_load

    for prefix, body_cut, card in cards:
        whole = card.crop(cinematic.card_box(body_cut)).resize((1024, 512), Image.LANCZOS)
        if prefix == "CardTall_":
            # The taller cut stacks the right rail's spikes; mirror the
            # left rail's clean stretch over them (mend_dialogue_rail.py).
            whole = mend_dialogue_rail.mend(whole)
        for suffix, left, top in (("TL", 0, 0), ("TR", 512, 0),
                                  ("BL", 0, 256), ("BR", 512, 256)):
            name = "UQ_AllianceLight_" + prefix + suffix + ".tga"
            write_tga(whole.crop((left, top, left + 512, top + 256)),
                      os.path.join(OUTPUT, name))


def write_portrait():
    frame = alliance_frame(cinematic.load(cinematic.FRAME))
    portrait = cinematic.lift_portrait(frame)
    write_tga(portrait.resize((256, 256), Image.LANCZOS),
              os.path.join(OUTPUT, "UQ_AllianceLight_Portrait.tga"))


def convert_one(source, target):
    image = rgba(source)
    name = os.path.basename(source)
    if name in ("UQ_HordeLight_Row.tga", "UQ_HordeLight_Gossip_Wood.tga"):
        output = blue_panel(image.size, image.getchannel("A"))
    elif name.startswith("UQ_HordeLight_Panel_"):
        # These pieces are mostly parchment. Preserve them byte-for-pixel so
        # aged stains never turn into faction-coloured splashes.
        output = image
    elif name == "UQ_HordeLight_Plate.tga":
        output = reward_plate(image, REWARD_STYLE)
    elif name == "UQ_HordeLight_Plate_Selected.tga":
        output = reward_plate(image, REWARD_SELECTED_STYLE)
    elif name == "UQ_HordeLight_Button.tga":
        output = recolor_gems(image)
    else:
        output = recolor(image)
    write_tga(output, target)


def main():
    if not os.path.isdir(OUTPUT):
        os.makedirs(OUTPUT)
    write_cards()
    write_portrait()
    for name in sorted(os.listdir(SOURCE)):
        source = os.path.join(SOURCE, name)
        if not os.path.isfile(source) or not name.lower().endswith(".tga"):
            continue
        if name.startswith("UQ_HordeLight_Card_") or name.startswith("UQ_HordeLight_CardTall_"):
            continue
        if name == "UQ_HordeLight_Portrait.tga":
            continue
        target_name = name.replace("UQ_HordeLight_", "UQ_AllianceLight_", 1)
        target = os.path.join(OUTPUT, target_name)
        convert_one(source, target)
        print("%-34s %s" % (target_name, rgba(target).size))

    print("palette blue=%s gold=%s silver=%s" %
          (PALETTE["blue"], PALETTE["gold"], PALETTE["silver"]))


if __name__ == "__main__":
    main()
