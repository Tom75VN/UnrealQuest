"""Build the Horde dialogue theme from its geometry-locked masters.

The card master is a complete frame with its parchment already inside. The
conversation card removes whole quiet row ranges from it; both cards are then
resized to the Cinematic card, the portrait opening is punched out, and a
separate portrait master covers it at runtime. Runtime assets retain
Cinematic's proven power-of-two sizes and type-10 RLE encoding.

Run from the addon root:  python tools/make_dialogue_horde.py
"""

import os

from PIL import Image, ImageChops, ImageDraw, ImageEnhance, ImageFilter

import make_dialogue_horde_light as cinematic


ROOT = os.getcwd()
DIALOGUES = os.path.join(ROOT, "media", "Textures", "Dialogues")
STYLE = os.path.join(DIALOGUES, "#src", "Horde")
SOURCE_RUNTIME = os.path.join(DIALOGUES, "HordeLight")
OUTPUT = os.path.join(DIALOGUES, "Horde")
PARCHMENT_OUTPUT = os.path.join(DIALOGUES, "Parchment")

FRAME = os.path.join(STYLE, "Orcish Horde Parchment UI Frame.png")
CONVERSATION_FRAME = os.path.join(STYLE, "HordeV2_Conversation_Frame.png")
PORTRAIT_STYLE = os.path.join(STYLE, "HordeV2_Portrait_Frame.png")
PANEL_STYLE = os.path.join(STYLE, "HordeV2_Panel.png")
REWARD_PANEL_STYLE = os.path.join(STYLE, "HordeV2_Reward_Panel.png")
PARCHMENT_STYLE = os.path.join(STYLE, "parchment.png")
RED_STYLE = os.path.join(STYLE, "HordeV2_Button_Red.png")
DARK_STYLE = os.path.join(STYLE, "HordeV2_Button_Dark.png")
GOSSIP_STYLE = os.path.join(STYLE, "HordeV2_Gossip_Option.png")
GOSSIP_FRAME_STYLE = os.path.join(STYLE, "HordeV2_Gossip_Frame.png")
TITLE_DIVIDER_STYLE = os.path.join(STYLE, "HordeV2_Title_Divider.png")
ALLIANCE_TITLE_DIVIDER = os.path.join(
    PARCHMENT_OUTPUT, "UQ_Parchment_Title_Divider.tga")
# The Horde crest drawn in the parchment's top right corner.
EMBLEM_STYLE = os.path.join(STYLE, "ChatGPT Image Oct 7, 2026, 07_49_31 PM-1.png")
# The crest's opacity, baked into its alpha: Texture:SetAlpha darkens rather
# than fades on this client (rendering.texture_setalpha_darkens_not_translucent).
EMBLEM_ALPHA = 0.28

# Measured on FRAME, which carries its own torn parchment. Both cards are cut
# from it whole; the portrait opening is punched out of the finished card.
#
# The conversation card has its own compact master so the side banners remain
# continuous instead of crossing a removed-row seam.
QUEST_CUTS = ()
# The parchment's shading differs across a removed range, so above each seam
# its columns fade into the rows just above the removed range's end. Only the
# parchment fades: the rails keep a hard cut, where the ornaments hide it.
SEAM_FADE = 48
SEAM_FADE_COLUMNS = (195, 1480)
SEAM_FADE_FEATHER = 30
CARD_HEIGHT = 305.7
CARD_TALL_HEIGHT = 373.9
# The Horde V2 `hole` in Compatibility/ClientAPI.lua; keep the two equal.
PORTRAIT_HOLE = (86.55, 122.67, 139.68, 128.67)
# The conversation card's smaller portrait: the Horde V2
# `conversationPortrait.hole`; keep the two equal.
CONVERSATION_PORTRAIT_HOLE = (87.92, 124.02, 119.84, 110.39)
# The objectives rule's ink.
OBJECTIVE_INK = (126, 40, 31)
REWARD_PARCHMENT_GRADE = (0.96, 0.89, 0.80)


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
    """Discard only nearly transparent generator edge noise."""
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
        cleaned.append((red, green, blue, alpha))
    image.putdata(cleaned)
    return image


def card_frame(cuts):
    """The master cropped to its frame, with `cuts` (source row ranges,
    top to bottom) removed across the full width."""
    frame = clean_fringe(rgba(FRAME))
    left, top, right, bottom = bounds(frame)
    kept = []
    y = top
    for cut_top, cut_bottom in cuts:
        kept.append((y, cut_top))
        y = cut_bottom
    kept.append((y, bottom))
    height = sum(b - a for a, b in kept)
    card = Image.new("RGBA", (right - left, height), (0, 0, 0, 0))
    y = 0
    for a, b in kept:
        card.paste(frame.crop((left, a, right, b)), (0, y))
        y += b - a
        if b == bottom:
            break
        # Rows just above the next kept piece, faded in over this piece's end.
        following = kept[kept.index((a, b)) + 1][0]
        fade = SEAM_FADE
        under = frame.crop((left, following - fade, right, following))
        card.paste(Image.composite(under, card.crop((0, y - fade, card.size[0], y)),
                                   seam_mask(under.size, left)), (0, y - fade))
    return card


def seam_mask(size, left):
    """Ramps 0 -> 255 downwards, inside the parchment columns only."""
    width, height = size
    columns = Image.new("L", (width, 1), 0)
    first, last = (column - left for column in SEAM_FADE_COLUMNS)
    feather = SEAM_FADE_FEATHER
    columns.putdata([int(round(255 * max(0.0, min(1.0, (x - first) / float(feather),
                                                      (last - x) / float(feather)))))
                     for x in range(width)])
    rows = Image.new("L", (1, height), 0)
    rows.putdata([int(round(255 * (y + 0.5) / height)) for y in range(height)])
    return ImageChops.multiply(columns.resize(size), rows.resize(size))


def master_crop(path):
    image = clean_fringe(rgba(path))
    box = bounds(image)
    if not box:
        raise ValueError("Horde V2 master has no visible bounds: " + path)
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


def reward_parchment(size, alpha):
    image = interior(PARCHMENT_STYLE, size, alpha)
    red, green, blue, image_alpha = image.split()
    channels = (red, green, blue)
    graded = []
    for index in range(3):
        factor = REWARD_PARCHMENT_GRADE[index]
        graded.append(channels[index].point(
            lambda value, factor=factor: int(round(value * factor))))
    return Image.merge("RGBA", (graded[0], graded[1], graded[2], image_alpha))


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

    outline(REWARD_LEFT_EDGE, (24, 15, 12, 255), 7)
    outline(REWARD_LEFT_EDGE, (78, 40, 28, 255), 5)
    outline(REWARD_LEFT_EDGE, (178, 92, 58, 255), 3)
    outline(REWARD_LEFT_EDGE, (239, 190, 132, 255), 1)
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

    master = RED_STYLE if selected else DARK_STYLE
    leather = interior(master, size, mask)
    image = Image.new("RGBA", size, (0, 0, 0, 0))
    image.alpha_composite(leather)

    trim_large = Image.new("RGBA", mask_large.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(trim_large)

    def outline(points, colour, width):
        path = list(scaled(points))
        path.append(path[0])
        draw.line(path, fill=colour, width=width * scale, joint="curve")

    outline(REWARD_OUTER, (24, 15, 12, 255), 7)
    outline(REWARD_OUTER, (78, 40, 28, 255), 5)
    outline(REWARD_OUTER, (178, 92, 58, 255), 3)
    outline(REWARD_OUTER, (239, 190, 132, 255), 1)

    body_inner = ((128, 25), (489, 25), (496, 32), (496, 96),
                  (489, 103), (128, 103))
    inner_path = list(scaled(body_inner))
    draw.line(inner_path, fill=(73, 35, 25, 255), width=2 * scale,
              joint="curve")
    if selected:
        draw.line(inner_path, fill=(226, 44, 30, 235), width=2 * scale,
                  joint="curve")

    def diamond(x, y, radius):
        points = scaled(((x, y - radius), (x + radius, y),
                         (x, y + radius), (x - radius, y)))
        draw.polygon(points, fill=(39, 23, 18, 255))
        inner = scaled(((x, y - radius + 2), (x + radius - 2, y),
                        (x, y + radius - 2), (x - radius + 2, y)))
        draw.polygon(inner, fill=(205, 83, 48, 255))

    for x, y in ((496, 20), (496, 108)):
        diamond(x, y, 7)

    trim = trim_large.resize(size, Image.LANCZOS)
    image.alpha_composite(trim)
    return image


def horde_grade(image):
    alpha = image.getchannel("A")
    rgb = ImageEnhance.Color(image.convert("RGB")).enhance(0.88)
    rgb = Image.blend(rgb, Image.new("RGB", image.size, (92, 33, 24)), 0.055)
    rgb = ImageEnhance.Contrast(rgb).enhance(1.07)
    rgb.putalpha(alpha)
    return rgb


def write_tga(image, name, folder=None, prefix="UQ_Horde_"):
    destination = folder or OUTPUT
    path = os.path.join(destination, prefix + name + ".tga")
    image.convert("RGBA").save(path, format="TGA", compression="tga_rle")
    with open(path, "rb") as handle:
        header = handle.read(18)
    if len(header) != 18 or header[2] != 10 or header[16] != 32 or header[17] != 8:
        raise ValueError("Horde V2 texture is not a 32-bit RLE type-10 TGA: " + path)
    print("%-36s %s" % (os.path.basename(path), image.size))


# The title rule's drawn box in design units (the Horde V2 `titleDivider` in
# Compatibility/ClientAPI.lua). The texture is laid out at this aspect before
# it is squeezed to its power-of-two size, so the box stretches it back and
# the diamonds keep their own proportions.
TITLE_DIVIDER_BOX = (354.58, 13)
# Measured on master_crop's 2036x94 result: the line spans rows 41..51 and
# the diamond cluster columns 912..1123. The rows keep a small transparent
# margin; only the plain line either side of the cluster is stretched.
TITLE_DIVIDER_ROWS = (-4, 98)
TITLE_DIVIDER_ORNAMENT = (904, 1132)


def title_divider(size):
    """The title rule extracted from the Horde V2 quest-frame reference."""
    master = master_crop(TITLE_DIVIDER_STYLE)
    top, bottom = TITLE_DIVIDER_ROWS
    left, right = TITLE_DIVIDER_ORNAMENT
    height = bottom - top
    width = int(round(height * TITLE_DIVIDER_BOX[0] / TITLE_DIVIDER_BOX[1]))
    ornament = master.crop((left, top, right, bottom))
    side = (width - ornament.size[0]) // 2
    rule = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    rule.paste(master.crop((0, top, left, bottom)).resize((side, height), Image.LANCZOS),
               (0, 0))
    rule.paste(ornament, (side, 0))
    right_side = width - side - ornament.size[0]
    rule.paste(master.crop((right, top, master.size[0], bottom)).resize(
        (right_side, height), Image.LANCZOS), (side + ornament.size[0], 0))
    return rule.resize(size, Image.LANCZOS)


def write_title_divider():
    write_tga(title_divider((512, 32)), "Title_Divider")


def write_parchment_objective_rule():
    """Horde objective-rule geometry in Classic's Alliance-divider ink."""
    reference = rgba(ALLIANCE_TITLE_DIVIDER)
    inks = set((red, green, blue) for red, green, blue, alpha
               in pixels(reference) if alpha > 0)
    if len(inks) != 1:
        raise ValueError("Alliance V2 title divider ink is not flat")
    ink = inks.pop()
    for name in ("Objective_Diamond", "Objective_Line"):
        source = rgba(os.path.join(OUTPUT, "UQ_Horde_" + name + ".tga"))
        source.putdata([ink + (alpha,)
                        for red, green, blue, alpha in pixels(source)])
        # A basename of its own: this client resolves addon textures by
        # file name alone (textures.addon_paths_resolved_by_basename), so a
        # copy named as Horde's red original drew whichever loaded first.
        write_tga(source, name, PARCHMENT_OUTPUT, "UQ_Parchment_")


def write_emblem():
    """The crest cropped to its ink and centred in a square at its own aspect."""
    crest = master_crop(EMBLEM_STYLE)
    side = max(crest.size)
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.paste(crest, ((side - crest.size[0]) // 2, (side - crest.size[1]) // 2))
    square = square.resize((256, 256), Image.LANCZOS)
    square.putalpha(square.getchannel("A").point(lambda value: int(value * EMBLEM_ALPHA + 0.5)))
    write_tga(square, "Emblem")


def write_card(card, prefix, height, portrait_hole):
    whole = card.resize((1024, 512), Image.LANCZOS)
    left, top, width, hole_height = portrait_hole
    hole = (int(round(left * 1024 / cinematic.CARD_WIDTH)),
            int(round(top * 512 / height)),
            int(round((left + width) * 1024 / cinematic.CARD_WIDTH)),
            int(round((top + hole_height) * 512 / height)))
    whole.paste((0, 0, 0, 0), hole)
    for suffix, left, top in (("TL", 0, 0), ("TR", 512, 0),
                              ("BL", 0, 256), ("BR", 512, 256)):
        write_tga(whole.crop((left, top, left + 512, top + 256)), prefix + suffix)


def write_cards():
    write_card(master_crop(CONVERSATION_FRAME), "Conversation_", CARD_HEIGHT,
               CONVERSATION_PORTRAIT_HOLE)
    write_card(card_frame(QUEST_CUTS), "Quest_", CARD_TALL_HEIGHT, PORTRAIT_HOLE)


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


def write_reward_panel():
    """Cut the slim reward border into stretch-safe, quiet nine-slices."""
    frame = master_crop(REWARD_PANEL_STYLE)
    width, height = frame.size
    corner = min(190, width // 3, height // 3)

    parchment_mask = Image.new("L", frame.size, 0)
    ImageDraw.Draw(parchment_mask).rounded_rectangle(
        (38, 30, width - 38, height - 30), radius=44, fill=255)
    parchment = reward_parchment(frame.size, parchment_mask)
    master = Image.new("RGBA", frame.size, (0, 0, 0, 0))
    master.alpha_composite(parchment)
    master.alpha_composite(frame)

    # Sample the quiet centre of each rail so a resized panel never stretches
    # one of the occasional iron straps; the corners stay in their own squares.
    horizontal_left = int(round(width * 0.44))
    horizontal_right = int(round(width * 0.56))
    vertical_top = int(round(height * 0.34))
    vertical_bottom = int(round(height * 0.46))
    slices = (
        ("TL", (128, 128), (0, 0, corner, corner)),
        ("T", (512, 64), (horizontal_left, 0, horizontal_right, corner)),
        ("TR", (128, 128), (width - corner, 0, width, corner)),
        ("L", (64, 256), (0, vertical_top, corner, vertical_bottom)),
        ("C", (512, 256), (corner, corner, width - corner, height - corner)),
        ("R", (64, 256), (width - corner, vertical_top, width, vertical_bottom)),
        ("BL", (128, 128), (0, height - corner, corner, height)),
        ("B", (512, 64),
         (horizontal_left, height - corner, horizontal_right, height)),
        ("BR", (128, 128),
         (width - corner, height - corner, width, height)),
    )
    for name, size, box in slices:
        write_tga(master.crop(box).resize(size, Image.LANCZOS),
                  "RewardPanel_" + name)


def write_controls():
    write_tga(reward_plate(False), "Reward_Item_Plate_Unified")
    write_tga(reward_plate(True), "Reward_Item_Plate_Unified_Selected")
    write_tga(reward_left_edge(), "Reward_Plate_Left_Edge")
    controls = ((cinematic.BUTTON, RED_STYLE, "Button"),)
    for source, master, name in controls:
        write_tga(control(source, master).resize((512, 128), Image.LANCZOS), name)


def runtime(name):
    return rgba(os.path.join(SOURCE_RUNTIME, "UQ_HordeLight_" + name + ".tga"))


def write_rows():
    geometry = runtime("Row")
    write_tga(interior(DARK_STYLE, geometry.size, geometry.getchannel("A")), "Row")
    for name, colour in (("Row_Hover", (153, 30, 23)),
                         ("Row_Selected", (226, 48, 32))):
        source = runtime(name)
        image = Image.new("RGBA", source.size, colour + (0,))
        image.putalpha(source.getchannel("A"))
        write_tga(image, name)


def write_gossip():
    banner = master_crop(GOSSIP_FRAME_STYLE)
    write_tga(banner.resize((512, 128), Image.LANCZOS), "Gossip_Frame")

    geometry = runtime("Gossip_Wood")
    scale = 4
    wood_alpha = Image.new("L", (geometry.size[0] * scale,
                                  geometry.size[1] * scale), 0)
    ImageDraw.Draw(wood_alpha).rounded_rectangle(
        (32 * scale, 4 * scale, (geometry.size[0] - 32) * scale,
         (geometry.size[1] - 4) * scale), radius=6 * scale, fill=255)
    wood_alpha = wood_alpha.resize(geometry.size, Image.LANCZOS)
    wood = interior(GOSSIP_STYLE, geometry.size, wood_alpha)
    write_tga(wood, "Gossip_Wood")


def write_flags():
    size = cinematic.FLAG_TEXTURE_SIZE
    for selected, name in ((False, "Flag"), (True, "Flag_Selected")):
        image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        draw = ImageDraw.Draw(image)
        if selected:
            glow = Image.new("RGBA", image.size, (0, 0, 0, 0))
            ImageDraw.Draw(glow).rounded_rectangle(
                (3, 4, 61, 60), radius=9, outline=(215, 42, 28, 190), width=6)
            image.alpha_composite(glow.filter(ImageFilter.GaussianBlur(2)))
            draw.rounded_rectangle((4, 5, 60, 59), radius=8,
                                   outline=(225, 148, 78, 255), width=4)
            draw.rounded_rectangle((7, 8, 57, 56), radius=6,
                                   outline=(225, 215, 196, 255), width=2)
        else:
            draw.rounded_rectangle((4, 5, 60, 59), radius=8,
                                   outline=(91, 34, 27, 255), width=3)
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
    """Warm-metal Horde variants of the proven Cinematic badge silhouettes."""
    for name in ("Kicker_Icon", "Kicker_Icon_TurnIn"):
        source = runtime(name)
        coloured = []
        for red, green, blue, alpha in pixels(source):
            value = (red + green + blue) / (3.0 * 255.0)
            low = (66, 25, 18)
            high = (244, 206, 126)
            coloured.append(tuple(int(round(low[index] +
                (high[index] - low[index]) * value)) for index in range(3)) + (alpha,))
        source.putdata(coloured)
        write_tga(source, name)


def main():
    if not os.path.isdir(OUTPUT):
        os.makedirs(OUTPUT)
    write_cards()
    write_title_divider()
    write_emblem()
    write_portrait()
    write_panel()
    write_reward_panel()
    write_controls()
    write_rows()
    write_gossip()
    write_flags()
    write_objective()
    write_parchment_objective_rule()
    write_kicker()


if __name__ == "__main__":
    main()
