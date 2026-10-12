"""Build the Alliance dialogue theme from its geometry-locked atlas.

The supplied Alliance atlas contains the full card frame and its portrait
frame as separate alpha components. The quest card is shortened at quiet runs
in the rails, composed over the Alliance V2 parchment, then split exactly like
the Cinematic card. The conversation card is its own complete authored frame
with the parchment already inside. Runtime assets retain Cinematic's proven
power-of-two sizes and type-10 RLE TGA encoding.

Run from the addon root:  python tools/make_dialogue_alliance.py
"""

import colorsys
import os

from PIL import Image, ImageDraw, ImageEnhance, ImageFilter

import make_dialogue_horde_light as cinematic


ROOT = os.getcwd()
DIALOGUES = os.path.join(ROOT, "media", "Textures", "Dialogues")
STYLE = os.path.join(DIALOGUES, "#src", "Alliance")
SOURCE_RUNTIME = os.path.join(DIALOGUES, "HordeLight")
OUTPUT = os.path.join(DIALOGUES, "Alliance")

ATLAS = os.path.join(STYLE, "ChatGPT Image Oct 7, 2026, 07_25_34 PM-1.png")
CONVERSATION_FRAME = os.path.join(STYLE, "AllianceV2_Frame.png")
PORTRAIT_STYLE = os.path.join(STYLE, "AllianceV2_Portrait_Frame.png")
PANEL_STYLE = os.path.join(STYLE, "AllianceV2_Panel.png")
BLUE_STYLE = os.path.join(STYLE, "AllianceV2_Button_Blue.png")
DARK_STYLE = os.path.join(STYLE, "AllianceV2_Button_Dark.png")
PARCHMENT = os.path.join(OUTPUT, "parchment.png")
# The Alliance crest drawn faint in the parchment's top right corner, as Horde
# V2's is (EMBLEM_ALPHA in tools/make_dialogue_horde.py).
EMBLEM_STYLE = os.path.join(OUTPUT, "UQ_AllianceLight_Emblem.tga.png")
EMBLEM_ALPHA = 0.28

# Measured on ATLAS. The portrait opening, including the old hanging banner,
# is cleared from the card before the standalone flag-free frame is overlaid.
ATLAS_CARD_BOX = (48, 6, 1624, 914)
ATLAS_PORTRAIT_CLEAR = (213, 286, 607, 771)

# Shorten the authored frame to Cinematic's two runtime aspect ratios. The
# whole cut lands in the long body rails, preserving the lion shield and title
# band exactly as supplied.
BAND_CUT = 0
BAND_CUT_SIDES = ((0, 205, 140), (205, 1467, 152), (1467, 1672, 140))
BODY_CUT = 199
BODY_CUT_TALL = 41
BODY_CUT_SIDES = ((0, 205, 655), (205, 1467, 644), (1467, 1672, 655))

# Keep the irregular paper edge only a few source pixels beneath the inner
# gold rails, so none of it can show beyond the frame's uneven silhouette.
BODY_FILL = (140, 235, 1531, 849)
HEADER_BLUE_BOXES = ((190, 80, 740, 235), (930, 80, 1490, 235))
CARD_HEIGHT = 305.7
CARD_TALL_HEIGHT = 373.9
# The title divider ends 8 pixels (10.29 units at the theme's 1.296 scale)
# short of the parchment's right edge (x 625) and sits 5 pixels higher (6.43
# units). Its ink matches the lower divider in the in-game reference.
TITLE_DIVIDER = (239.14, 155.57, 375.57, 13)
TITLE_DIVIDER_INK = (120, 86, 48)
TITLE_DIVIDER_ALPHA = 1.0
# The objectives rule's ink.
OBJECTIVE_INK = (52, 86, 151)


def rgba(path):
    return Image.open(path).convert("RGBA")


def pixels(image):
    if hasattr(image, "get_flattened_data"):
        return image.get_flattened_data()
    return image.getdata()


def bounds(image, threshold=24):
    return image.getchannel("A").point(
        lambda value: 255 if value > threshold else 0).getbbox()


def clean_fringe(image, keep=None):
    """Discard generator edge noise outside the blue/gold/silver palette,
    leaving the optional `keep` box untouched."""
    cleaned = []
    width = image.size[0]
    for index, (red, green, blue, alpha) in enumerate(pixels(image)):
        if keep:
            x, y = index % width, index // width
            if keep[0] <= x < keep[2] and keep[1] <= y < keep[3]:
                cleaned.append((red, green, blue, alpha))
                continue
        if alpha < 10:
            alpha = 0
        elif red > 105 and green < 52 and blue < 58:
            alpha = 0
        elif green > 90 and red < 62 and blue < 68:
            alpha = 0
        cleaned.append((red, green, blue, alpha))
    image.putdata(cleaned)
    return image


def match_header_blue(image, boxes=HEADER_BLUE_BOXES):
    """Match the reference navy while preserving the authored leather pattern."""
    for box in boxes:
        region = image.crop(box)
        adjusted = []
        for red, green, blue, alpha in pixels(region):
            hue, saturation, value = colorsys.rgb_to_hsv(
                red / 255.0, green / 255.0, blue / 255.0)
            if alpha > 24 and 0.55 < hue < 0.72 and saturation > 0.45:
                hue = min(1.0, hue + 0.009)
                saturation = min(1.0, saturation * 0.836)
                value = max(0.0, min(1.0, 0.284 + (value - 0.3394) * 1.095))
                red, green, blue = (
                    int(round(channel * 255.0))
                    for channel in colorsys.hsv_to_rgb(hue, saturation, value))
            adjusted.append((red, green, blue, alpha))
        region.putdata(adjusted)
        image.alpha_composite(region, (box[0], box[1]))
    return image


def card_box(body_cut):
    return (ATLAS_CARD_BOX[0], ATLAS_CARD_BOX[1], ATLAS_CARD_BOX[2],
            ATLAS_CARD_BOX[3] - BAND_CUT - body_cut)


def card_frame():
    frame = match_header_blue(clean_fringe(rgba(ATLAS)))
    frame.paste((0, 0, 0, 0), ATLAS_PORTRAIT_CLEAR)
    return frame


def cut_frame(frame, body_cut):
    frame = cinematic.cut_rows(frame, body_cut, BODY_CUT_SIDES)
    return cinematic.cut_rows(frame, BAND_CUT, BAND_CUT_SIDES)


def body_fill(body_cut):
    left, top, right, bottom = BODY_FILL
    return (left, top - BAND_CUT, right, bottom - BAND_CUT - body_cut)


def fit_parchment(size):
    """Fit the complete parchment edge treatment without widening its corners."""
    parchment = clean_fringe(rgba(PARCHMENT))
    parchment = parchment.crop(bounds(parchment, 4))
    width = int(round(parchment.size[0] * size[1] / parchment.size[1]))
    parchment = parchment.resize((width, size[1]), Image.LANCZOS)

    side = min(int(round(width * 0.12)), size[0] // 3)
    centre_width = size[0] - side * 2
    fitted = Image.new("RGBA", size, (0, 0, 0, 0))
    fitted.alpha_composite(parchment.crop((0, 0, side, size[1])), (0, 0))
    centre = parchment.crop((side, 0, width - side, size[1]))
    fitted.alpha_composite(centre.resize((centre_width, size[1]), Image.LANCZOS),
                           (side, 0))
    fitted.alpha_composite(
        parchment.crop((width - side, 0, width, size[1])),
        (size[0] - side, 0))
    return fitted


def fit_tall_parchment(size):
    """Enlarge the authored perimeter while keeping its contour under the frame."""
    parchment = clean_fringe(rgba(PARCHMENT))
    parchment = parchment.crop(bounds(parchment, 4))
    width, height = parchment.size
    target_width, target_height = size

    source_x = (0, 280, width - 280, width)
    source_y = (0, 180, height - 230, height)
    target_x = (0, 340, target_width - 340, target_width)
    target_y = (0, 150, target_height - 240, target_height)

    fitted = Image.new("RGBA", size, (0, 0, 0, 0))
    for row in range(3):
        for column in range(3):
            source = (source_x[column], source_y[row],
                      source_x[column + 1], source_y[row + 1])
            target = (target_x[column], target_y[row],
                      target_x[column + 1], target_y[row + 1])
            tile = parchment.crop(source).resize(
                (target[2] - target[0], target[3] - target[1]), Image.LANCZOS)
            fitted.alpha_composite(tile, (target[0], target[1]))
    return fitted


def master_crop(path):
    image = clean_fringe(rgba(path))
    box = bounds(image)
    if not box:
        raise ValueError("Alliance V2 master has no visible bounds: " + path)
    return image.crop(box)


def interior(path, size, alpha):
    """Sample only a control master's quiet centre, never its ornate caps."""
    image = master_crop(path)
    width, height = image.size
    image = image.crop((int(width * 0.18), int(height * 0.28),
                        int(width * 0.82), int(height * 0.72)))
    image = ImageEnhance.Contrast(image).enhance(1.04)
    image = image.resize(size, Image.LANCZOS)
    image.putalpha(alpha)
    return image


def control(source_name, master_path):
    """Apply a generated control face to an established control silhouette."""
    geometry = cinematic.load(source_name)
    geometry = geometry.crop(cinematic.bounds(geometry))
    style = master_crop(master_path).resize(geometry.size, Image.LANCZOS)
    style.putalpha(geometry.getchannel("A"))
    return style


REWARD_OUTER = ((14, 2), (114, 2), (124, 12), (124, 18),
                (495, 18), (503, 26), (503, 102), (495, 110),
                (124, 110), (124, 116), (114, 126), (14, 126),
                (8, 116), (8, 12))
REWARD_LEFT_EDGE = ((128, 18), (124, 18), (124, 12), (114, 2),
                    (14, 2), (8, 12), (8, 116), (14, 126),
                    (114, 126), (124, 116), (124, 110), (128, 110))


def reward_left_edge():
    """Outer row edge above the icon, without a separate item frame."""
    scale = 4
    canvas = Image.new("RGBA", (128 * scale, 128 * scale), (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)

    def scaled(points):
        return tuple((x * scale, y * scale) for x, y in points)

    def outline(points, colour, width):
        path = list(scaled(points))
        draw.line(path, fill=colour, width=width * scale, joint="curve")

    outline(REWARD_LEFT_EDGE, (30, 20, 10, 255), 7)
    outline(REWARD_LEFT_EDGE, (104, 63, 17, 255), 5)
    outline(REWARD_LEFT_EDGE, (210, 145, 36, 255), 3)
    outline(REWARD_LEFT_EDGE, (255, 218, 112, 255), 1)
    return canvas.resize((128, 128), Image.LANCZOS)


def reward_plate(selected=False):
    """One continuous leather reward row around the icon and name."""
    size = (512, 128)
    scale = 4

    def scaled(points):
        return tuple((x * scale, y * scale) for x, y in points)

    mask_large = Image.new("L", (size[0] * scale, size[1] * scale), 0)
    mask_draw = ImageDraw.Draw(mask_large)
    mask_draw.polygon(scaled(REWARD_OUTER), fill=255)
    mask = mask_large.resize(size, Image.LANCZOS)

    master = BLUE_STYLE if selected else DARK_STYLE
    leather = interior(master, size, mask)
    image = Image.new("RGBA", size, (0, 0, 0, 0))
    image.alpha_composite(leather)

    trim_large = Image.new("RGBA", mask_large.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(trim_large)

    def outline(points, colour, width):
        path = list(scaled(points))
        path.append(path[0])
        draw.line(path, fill=colour, width=width * scale, joint="curve")

    outline(REWARD_OUTER, (30, 20, 10, 255), 7)
    outline(REWARD_OUTER, (104, 63, 17, 255), 5)
    outline(REWARD_OUTER, (210, 145, 36, 255), 3)
    outline(REWARD_OUTER, (255, 218, 112, 255), 1)

    body_inner = ((128, 25), (489, 25), (496, 32), (496, 96),
                  (489, 103), (128, 103))
    inner_path = list(scaled(body_inner))
    draw.line(inner_path, fill=(76, 46, 16, 255), width=2 * scale,
              joint="curve")
    if selected:
        draw.line(inner_path, fill=(53, 126, 255, 230), width=2 * scale,
                  joint="curve")

    def diamond(x, y, radius):
        points = scaled(((x, y - radius), (x + radius, y),
                         (x, y + radius), (x - radius, y)))
        draw.polygon(points, fill=(45, 28, 12, 255))
        inner = scaled(((x, y - radius + 2), (x + radius - 2, y),
                        (x, y + radius - 2), (x - radius + 2, y)))
        draw.polygon(inner, fill=(231, 169, 55, 255))

    for x, y in ((496, 20), (496, 108)):
        diamond(x, y, 7)

    trim = trim_large.resize(size, Image.LANCZOS)
    image.alpha_composite(trim)
    return image


def cool_grade(image):
    alpha = image.getchannel("A")
    rgb = ImageEnhance.Color(image.convert("RGB")).enhance(0.95)
    rgb = Image.blend(rgb, Image.new("RGB", image.size, (43, 70, 126)), 0.065)
    rgb = ImageEnhance.Contrast(rgb).enhance(1.03)
    rgb.putalpha(alpha)
    return rgb


def write_tga(image, name, folder=None):
    destination = folder or OUTPUT
    path = os.path.join(destination, "UQ_Alliance_" + name + ".tga")
    image.convert("RGBA").save(path, format="TGA", compression="tga_rle")
    with open(path, "rb") as handle:
        header = handle.read(18)
    if len(header) != 18 or header[2] != 10 or header[16] != 32 or header[17] != 8:
        raise ValueError("Alliance V2 texture is not a 32-bit RLE type-10 TGA: " + path)
    print("%-36s %s" % (os.path.basename(path), image.size))


def composed_card(body_cut):
    frame = cut_frame(card_frame(), body_cut)
    card = Image.new("RGBA", frame.size, (0, 0, 0, 0))

    box = body_fill(body_cut)
    size = (box[2] - box[0], box[3] - box[1])
    if body_cut == BODY_CUT_TALL:
        parchment = fit_tall_parchment(size)
    else:
        parchment = fit_parchment(size)
    card.alpha_composite(parchment, (box[0], box[1]))

    card.alpha_composite(frame)
    return card


def conversation_card():
    frame = rgba(CONVERSATION_FRAME)
    return frame.crop(bounds(frame))


def title_divider(size):
    """Cinematic's exact ornament in the lower divider's brown ink."""
    divider = cinematic.wide_divider().resize(size, Image.LANCZOS)
    recoloured = []
    for red, green, blue, alpha in pixels(divider):
        recoloured.append(TITLE_DIVIDER_INK
                          + (int(round(alpha * TITLE_DIVIDER_ALPHA)),))
    divider.putdata(recoloured)
    return divider


def add_title_divider(card, card_height):
    left, top, width, height = TITLE_DIVIDER
    x = int(round(left * card.size[0] / cinematic.CARD_WIDTH))
    y = int(round(top * card.size[1] / card_height))
    w = int(round(width * card.size[0] / cinematic.CARD_WIDTH))
    h = int(round(height * card.size[1] / card_height))
    card.alpha_composite(title_divider((w, h)), (x, y))


def write_title_divider():
    """Export the card's exact ornament for Classic's under-title rule."""
    write_tga(title_divider((512, 32)), "Title_Divider",
              os.path.join(DIALOGUES, "Parchment"))


def write_card(card, prefix, height):
    whole = card.resize((1024, 512), Image.LANCZOS)
    add_title_divider(whole, height)
    for suffix, left, top in (("TL", 0, 0), ("TR", 512, 0),
                              ("BL", 0, 256), ("BR", 512, 256)):
        write_tga(whole.crop((left, top, left + 512, top + 256)), prefix + suffix)


def write_conversation_card():
    write_card(conversation_card(), "Conversation_", CARD_HEIGHT)


def write_cards():
    write_conversation_card()
    quest = composed_card(BODY_CUT_TALL).crop(card_box(BODY_CUT_TALL))
    write_card(quest, "Quest_", CARD_TALL_HEIGHT)


def write_portrait():
    portrait = master_crop(PORTRAIT_STYLE)
    write_tga(portrait.resize((256, 256), Image.LANCZOS), "Portrait_Frame")


def write_panel():
    panel = master_crop(PANEL_STYLE)
    width, height = panel.size
    edge = min(cinematic.PANEL_EDGE, width // 4, height // 4)
    slices = (
        ("TL", (128, 128), (0, 0, edge, edge)),
        ("T", (512, 64), (edge, 0, width - edge, edge)),
        ("TR", (128, 128), (width - edge, 0, width, edge)),
        ("L", (64, 256), (0, edge, edge, height - edge)),
        ("C", (512, 256), (edge, edge, width - edge, height - edge)),
        ("R", (64, 256), (width - edge, edge, width, height - edge)),
        ("BL", (128, 128), (0, height - edge, edge, height)),
        ("B", (512, 64), (edge, height - edge, width - edge, height)),
        ("BR", (128, 128), (width - edge, height - edge, width, height)),
    )
    for name, size, box in slices:
        write_tga(panel.crop(box).resize(size, Image.LANCZOS), "Panel_" + name)


def write_controls():
    write_tga(reward_plate(False), "Reward_Item_Plate_Unified")
    write_tga(reward_plate(True), "Reward_Item_Plate_Unified_Selected")
    write_tga(reward_left_edge(), "Reward_Plate_Left_Edge")
    controls = ((cinematic.BUTTON, BLUE_STYLE, "Button"),)
    for source, master, name in controls:
        write_tga(control(source, master).resize((512, 128), Image.LANCZOS), name)


def runtime(name):
    return rgba(os.path.join(SOURCE_RUNTIME, "UQ_HordeLight_" + name + ".tga"))


def write_rows():
    geometry = runtime("Row")
    write_tga(interior(DARK_STYLE, geometry.size, geometry.getchannel("A")), "Row")
    for name, colour in (("Row_Hover", (25, 87, 210)),
                         ("Row_Selected", (45, 119, 255))):
        source = runtime(name)
        image = Image.new("RGBA", source.size, colour + (0,))
        image.putalpha(source.getchannel("A"))
        write_tga(image, name)


def write_gossip():
    banner = control(cinematic.BUTTON, DARK_STYLE)
    width, height = banner.size
    left, top, right, bottom, radius = cinematic.GOSSIP_INTERIOR
    mask = Image.new("L", (width * 4, height * 4), 255)
    ImageDraw.Draw(mask).rounded_rectangle(
        (left * 4, top * 4, right * 4, bottom * 4), radius=radius * 4, fill=0)
    mask = mask.resize((width, height), Image.LANCZOS)
    alpha = Image.composite(banner.getchannel("A"), Image.new("L", banner.size, 0), mask)
    banner.putalpha(alpha)
    write_tga(banner.resize((512, 128), Image.LANCZOS), "Gossip_Frame")

    geometry = runtime("Gossip_Wood")
    wood = interior(DARK_STYLE, geometry.size, geometry.getchannel("A"))
    write_tga(wood, "Gossip_Wood")


def write_flags():
    size = cinematic.FLAG_TEXTURE_SIZE
    for selected, name in ((False, "Flag"), (True, "Flag_Selected")):
        image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        draw = ImageDraw.Draw(image)
        if selected:
            glow = Image.new("RGBA", image.size, (0, 0, 0, 0))
            ImageDraw.Draw(glow).rounded_rectangle(
                (3, 4, 61, 60), radius=9, outline=(28, 105, 255, 190), width=6)
            image.alpha_composite(glow.filter(ImageFilter.GaussianBlur(2)))
            draw.rounded_rectangle((4, 5, 60, 59), radius=8,
                                   outline=(232, 174, 46, 255), width=4)
            draw.rounded_rectangle((7, 8, 57, 56), radius=6,
                                   outline=(192, 210, 235, 255), width=2)
        else:
            draw.rounded_rectangle((4, 5, 60, 59), radius=8,
                                   outline=(20, 49, 105, 255), width=3)
        write_tga(image, name)


def write_objective():
    ink = OBJECTIVE_INK
    line =Image.new("RGBA", (64, 8), ink + (0,))
    alpha = Image.new("L", line.size, 0)
    draw = ImageDraw.Draw(alpha)
    draw.rectangle((0, 3, 63, 4), fill=225)
    draw.rectangle((0, 2, 63, 2), fill=55)
    draw.rectangle((0, 5, 63, 5), fill=55)
    line.putalpha(alpha)
    write_tga(line, "Objective_Line")

    size = 256
    centre = size // 2
    diamond = Image.new("RGBA", (size, size), ink + (0,))
    alpha = Image.new("L", diamond.size, 0)
    draw = ImageDraw.Draw(alpha)
    draw.polygon(((centre, 8), (size - 8, centre), (centre, size - 8), (8, centre)),
                 fill=255)
    draw.polygon(((centre, 64), (size - 64, centre), (centre, size - 64), (64, centre)),
                 fill=0)
    diamond.putalpha(alpha)
    write_tga(diamond.resize((32, 32), Image.LANCZOS), "Objective_Diamond")


def write_kicker():
    """The quest page's "!" and "?" badges from their authored masters, each
    cropped to a square around its visible bounds and kept at Cinematic's
    64 px badge size."""
    for name in ("Kicker_Icon", "Kicker_Icon_TurnIn"):
        image = rgba(os.path.join(OUTPUT, "UQ_Alliance_" + name + ".png"))
        left, top, right, bottom = bounds(image)
        side = max(right - left, bottom - top)
        centre_x = (left + right) // 2
        centre_y = (top + bottom) // 2
        square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
        square.alpha_composite(image.crop((centre_x - side // 2, centre_y - side // 2,
                                           centre_x - side // 2 + side,
                                           centre_y - side // 2 + side)))
        write_tga(square.resize((64, 64), Image.LANCZOS), name)


def write_emblem():
    """The crest cropped to its ink and centred in a 256 px square at its own
    aspect, its faintness baked into the alpha like Horde V2's: Texture:SetAlpha
    darkens rather than fades on this client."""
    crest = rgba(EMBLEM_STYLE)
    crest = crest.crop(bounds(crest))
    side = max(crest.size)
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.paste(crest, ((side - crest.size[0]) // 2, (side - crest.size[1]) // 2))
    square = square.resize((256, 256), Image.LANCZOS)
    square.putalpha(square.getchannel("A").point(lambda value: int(value * EMBLEM_ALPHA + 0.5)))
    write_tga(square, "Emblem")


def main():
    if not os.path.isdir(OUTPUT):
        os.makedirs(OUTPUT)
    write_cards()
    write_title_divider()
    write_portrait()
    write_panel()
    write_controls()
    write_rows()
    write_gossip()
    write_flags()
    write_objective()
    write_kicker()
    write_emblem()


if __name__ == "__main__":
    main()
