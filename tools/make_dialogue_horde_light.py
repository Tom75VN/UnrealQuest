"""Build the Horde light quest dialogue theme's textures from the authored sources.

Sources: media/Textures/Dialogues/#src/ (authored art, kept as delivered).
Output:  media/Textures/Dialogues/HordeLight/UQ_HordeLight_*.tga

What each output is, and how Compatibility/ClientAPI.lua draws it
(Client.QUEST_DIALOGUE_HORDE_LIGHT):

  Card_TL/TR/BL/BR  The card, composed once here: the bronze dialogue frame
                    (title band, portrait box) over a wood band and a clean
                    parchment body, with the ornate divider under the quest
                    title. Cut into a 2x2 grid of 512x256 tiles because no
                    texture larger than 512 px is proven on this client.
  CardTall_TL/TR/BL/BR
                    The same card made OBJECTIVE_ROWS source rows taller below
                    the portrait (BODY_CUT_TALL), for quest pages: the room
                    the objectives strip takes at the bottom.
  Objective_Line / Objective_Diamond
                    The thin rule with a diamond at its centre that heads the
                    objectives strip, drawn as two runs of line and the
                    diamond between them so nothing is stretched out of shape
                    (its badge is UQ_Dialogue_Crosshair).
  Kicker_Icon / Kicker_Icon_TurnIn
                    The quest kicker above the title: a gold "!" badge (a
                    quest to accept) or "?" badge (one to turn in) and the
                    thin line with its diamond end that runs on from the
                    "Quest" label. Separate from the card because gossip pages
                    have no kicker.
  Portrait          The gold portrait frame, lifted out of FRAME on its own:
                    transparent around it and through its opening. The card
                    is composed without it, so the parchment runs under the
                    frame, and cuts a hole there only as large as the opening
                    for the 3D model (rendering.model_m2_spell_fx_in_ui); this
                    is drawn over the model, so its border covers the model's
                    edges.
  Portrait_Background (Dialogues/UQ_Portrait_Background_Wide, every theme)
                    The scene behind the 3D model: GLADE cropped to the
                    portrait hole's aspect (PORTRAIT_HOLE_ASPECT), resized to
                    256x256 and drawn back at that aspect.
  Row / Row_Hover / Row_Selected
                    The dark wood plank: the gossip rows and the reward
                    inspector's cards, so their light text keeps reading.
                    Hover and Selected are warm glows drawn over the plank.
  Gossip_Frame / Gossip_Wood
                    The gossip rows: BUTTON's ornate frame with its parchment
                    cleared (GOSSIP_INTERIOR), drawn in three parts like the
                    banners, over the wood plank cropped -- never stretched --
                    to the exact aspect of the box it fills inside a 330x32
                    row (GOSSIP_WOOD_ASPECT), so the grain keeps its shape.
  Panel_TL..BR, C   Nine slices of the ornate parchment frame: the rewards and
                    turn-in panel under the card and the reward inspector.
  Flag / Flag_Selected
                    Transparent rims drawn directly over the dialogue language
                    flags; the selected rim is the rounded double gold state.
  Flag / Flag_Selected
                    Compact dark plaques behind the dialogue language flags;
                    the selected plaque carries the rounded double gold rim.
  Plate / Plate_Selected / Button
                    Banners drawn in three parts (caps of CAP_SHARE of the
                    drawn height, the centre stretched): the reward tiles and
                    the inspector's action buttons.

Every output is 32-bit RLE TGA type 10 with descriptor 0x08
(textures.uncompressed_512_tga_atlas_corrupts), at a power-of-two size.
The geometry constants below are mirrored in Client.QUEST_DIALOGUE_HORDE_LIGHT;
change them together.

Run from the addon root:  python tools/make_dialogue_horde_light.py
Pass --preview PATH to also write a mock-up of the card with sample text.
Pass --panel-preview PATH to write the composed reward panel before slicing.
Pass --flag-preview PATH to write the two language-flag plaques side by side.
Pass --flag-preview PATH to write the two language-flag plaques side by side.
"""

import os
import sys

from PIL import Image, ImageChops, ImageDraw, ImageEnhance, ImageFilter

import mend_dialogue_rail

ROOT = os.getcwd()
SOURCE = os.path.join(ROOT, "media", "Textures", "Dialogues", "#src")
OUTPUT = os.path.join(ROOT, "media", "Textures", "Dialogues", "HordeLight")

FRAME = "ChatGPT Image Oct 5, 2026, 10_22_00 PM.png"
PLANK = "ChatGPT Image Oct 5, 2026, 10_21_46 PM.png"
PARCHMENT = "wow_quest_parchment_clean.png"
DIVIDERS = "wow_quest_dividers_overlay.png"
PANEL = "Ornate Empty Parchment UI Frame.png"
PLATE = "Fantasy Parchment UI Banner.png"
PLATE_SELECTED = "Ornate Fantasy Parchment UI Banner.png"
BUTTON = "Slim Ornate Fantasy Parchment Banner.png"
GLADE = "Dreamy Golden-Hour Woodland Glade.png"

# The wood band is made BAND_CUT source rows shorter than FRAME draws it:
# that many rows are cut out of each side of the frame where it is plain --
# the left rail around its knot (dropping the knot), the empty band interior,
# the plain right rail -- so the rails stay continuous. (x from, x to, first
# cut row) per side, measured on FRAME's alpha.
BAND_CUT = 30
BAND_CUT_SIDES = ((0, 200, 166), (200, 1500, 150), (1500, 1672, 168))


# The body is made BODY_CUT source rows shorter below the portrait, so the
# parchment under the portrait frame is as deep as above it (frame top 290 is
# 38 rows under the band, frame bottom 677 was 153 rows over the bottom rail
# at 830). Cut per side where the rails match best across the seam, like the
# band cut; the middle is empty there.
BODY_CUT = 115
BODY_CUT_SIDES = ((0, 200, 393), (200, 1500, 691), (1500, 1672, 457))
# The quest-page card: rows added at the same seams instead of cut, by
# repeating the plain rail band just above each seam. A negative cut adds.
BODY_CUT_TALL = -42


def below_band(box):
    """A box measured on FRAME under the band, moved up with the cut."""
    return (box[0], box[1] - BAND_CUT, box[2], box[3] - BAND_CUT)


# Measured on FRAME (source pixels), then moved with the band cut. The card
# is the frame's own bounds.
def card_box(body_cut):
    return (53, 37, 1619, 886 - BAND_CUT - body_cut)


def body_fill(body_cut):
    """Under the body rails."""
    return below_band((100, 245, 1572, 842 - body_cut))


CARD_BOX = card_box(BODY_CUT)
BAND_FILL = (100, 80, 1572, 240 - BAND_CUT)        # under the band rails
# The portrait frame on FRAME, before the band cut: the box holding it and
# nothing else (diamond top 277, rails' torn edge above ends at 263), and its
# opening, inside the gold border.
PORTRAIT_FRAME = (159, 276, 591, 680)
PORTRAIT_OPENING = (192, 317, 557, 649)
# The ornate divider, under the quest title and flush with its left edge (card
# units y 143..156, the title box ending at 143), run on to the text column's
# right edge (card unit 648, QUEST_DIALOGUE_LAYOUTS["horde-light"].body) by
# stretching only its two plain line runs: the diamond end, the three centre
# diamonds and the tapered end keep their shape. DIVIDER_PARTS are the x
# where those runs start and end in the cropped source.
DIVIDER_SOURCE = (623, 419, 1368, 449)
DIVIDER_LEFT = 632
DIVIDER_RIGHT_UNITS = 648
DIVIDER_PARTS = (30, 345, 420, 712)
DIVIDER_TOP = 396 - BAND_CUT

# BUTTON's parchment, inside the dark outline, on its alpha bounds: the
# rounded box the gossip frame clears (left, top, right, bottom, radius).
GOSSIP_INTERIOR = (94, 62, 2018, 352, 127)
# The gossip wood box inside a 330x32 row, in design units (Lua's
# QUEST_DIALOGUE_HORDE_LIGHT.GOSSIP_WOOD): 316 x 23.
GOSSIP_WOOD_ASPECT = 316.0 / 23.0

# Width over height of the portrait hole (QUEST_DIALOGUE_LAYOUTS["horde-light"].hole).
PORTRAIT_HOLE_ASPECT = 164.5 / 150.2

# Card units: Client.QUEST_DIALOGUE_HORDE_LIGHT.WIDTH over the card box width.
CARD_WIDTH = 680

# Panel nine-slice grid, source pixels from each edge of PANEL's bounds.
PANEL_EDGE = 170
PANEL_PARCHMENT_BRIGHTNESS = 0.88
PANEL_PARCHMENT_CONTRAST = 1.20
PANEL_PARCHMENT_MASK_DARK = 115
PANEL_PARCHMENT_MASK_LIGHT = 185

# Share of a banner's height its end caps take, ornaments included.
CAP_SHARE = 0.55
FLAG_TEXTURE_SIZE = 64
FLAG_TEXTURE_SIZE = 64


def load(name):
    return Image.open(os.path.join(SOURCE, name)).convert("RGBA")


def bounds(image, threshold=24):
    return image.getchannel("A").point(lambda v: 255 if v > threshold else 0).getbbox()


def write_tga_rle(image, name):
    path = os.path.join(OUTPUT, "UQ_HordeLight_" + name + ".tga")
    image.convert("RGBA").save(path, format="TGA", compression="tga_rle")
    with open(path, "rb") as handle:
        header = handle.read(18)
    if len(header) != 18 or header[2] != 10 or header[16] != 32 or header[17] != 8:
        raise ValueError("RLE TGA writer did not produce the proven type-10 header")
    print("%-28s %4dx%-4d %8d bytes" % (os.path.basename(path), image.size[0],
                                         image.size[1], os.path.getsize(path)))


def cut_rows(frame, rows, sides):
    """Cuts `rows` source rows at each side's seam, or adds -rows there by
    repeating the REPEAT_BAND rows just above the seam."""
    width, height = frame.size
    cut = Image.new("RGBA", (width, height - rows), (0, 0, 0, 0))
    for left, right, row in sides:
        cut.paste(frame.crop((left, 0, right, row)), (left, 0))
        if rows >= 0:
            cut.paste(frame.crop((left, row + rows, right, height)), (left, row))
            continue
        band = frame.crop((left, row - REPEAT_BAND, right, row))
        y = row
        while y < row - rows:
            piece = band.crop((0, 0, right - left, min(REPEAT_BAND, row - rows - y)))
            cut.paste(piece, (left, y))
            y += REPEAT_BAND
        cut.paste(frame.crop((left, row, right, height)), (left, row - rows))
    return cut


REPEAT_BAND = 12


def cut_band(frame):
    return cut_rows(frame, BAND_CUT, BAND_CUT_SIDES)


def card_units(box):
    """A FRAME box (before the band cut) in card units, as Lua's boxes are:
    left, top, width, height."""
    scale = float(CARD_WIDTH) / (CARD_BOX[2] - CARD_BOX[0])
    left, top, right, bottom = below_band(box)
    return tuple(round(v, 1) for v in ((left - CARD_BOX[0]) * scale,
                                       (top - CARD_BOX[1]) * scale,
                                       (right - left) * scale, (bottom - top) * scale))


def lift_portrait(frame):
    """Takes the portrait frame out of `frame`; returns it on its own."""
    portrait = frame.crop(PORTRAIT_FRAME)
    frame.paste((0, 0, 0, 0), PORTRAIT_FRAME)
    return portrait


def wide_divider():
    """The divider stretched to end at DIVIDER_RIGHT_UNITS, its ornaments kept."""
    divider = load(DIVIDERS).crop(DIVIDER_SOURCE)
    width, height = divider.size
    right = CARD_BOX[0] + int(round(DIVIDER_RIGHT_UNITS * (CARD_BOX[2] - CARD_BOX[0])
                                    / float(CARD_WIDTH)))
    target = right - DIVIDER_LEFT
    a, b, c, d = DIVIDER_PARTS
    extra = target - width
    first = (b - a) + extra // 2
    second = (d - c) + extra - extra // 2
    # Both ends are the diamond end: the right one is the left mirrored, in
    # place of the source's tapered end.
    cap = divider.crop((0, 0, a, height))
    second = target - a - first - (c - b) - a
    pieces = (
        cap,
        divider.crop((a, 0, b, height)).resize((first, height), Image.LANCZOS),
        divider.crop((b, 0, c, height)),
        divider.crop((c, 0, d, height)).resize((second, height), Image.LANCZOS),
        cap.transpose(Image.FLIP_LEFT_RIGHT),
    )
    wide = Image.new("RGBA", (target, height), (0, 0, 0, 0))
    x = 0
    for piece in pieces:
        wide.paste(piece, (x, 0))
        x += piece.size[0]
    return wide


def compose_card(body_cut=BODY_CUT):
    frame = load(FRAME)
    lift_portrait(frame)
    frame = cut_band(cut_rows(frame, body_cut, BODY_CUT_SIDES))
    card = Image.new("RGBA", frame.size, (0, 0, 0, 0))

    parchment = load(PARCHMENT)
    left, top, right, bottom = bounds(parchment)
    inset = 46  # past the torn edge
    body = parchment.crop((left + inset, top + inset, right - inset, bottom - inset))
    box = body_fill(body_cut)
    card.alpha_composite(body.resize((box[2] - box[0], box[3] - box[1]), Image.LANCZOS),
                         (box[0], box[1]))

    plank = load(PLANK)
    left, top, right, bottom = bounds(plank)
    wood = plank.crop((left + 40, top + 14, right - 40, bottom - 14))
    wood = ImageEnhance.Brightness(wood).enhance(0.92)
    box = BAND_FILL
    card.alpha_composite(wood.resize((box[2] - box[0], box[3] - box[1]), Image.LANCZOS),
                         (box[0], box[1]))

    card.alpha_composite(wide_divider(), (DIVIDER_LEFT, DIVIDER_TOP))

    card.alpha_composite(frame)
    return card


def write_card(card, body_cut=BODY_CUT, prefix="Card_"):
    box = card_box(body_cut)
    whole = card.crop(box).resize((1024, 512), Image.LANCZOS)
    if prefix == "CardTall_":
        # The taller cut repeats each rail's band above its seam; mirror the
        # other rail's clean stretch over it (mend_dialogue_rail.py).
        whole = mend_dialogue_rail.mend(whole, mend_dialogue_rail.HORDE_LIGHT_MENDS)
    for name, x, y in (("TL", 0, 0), ("TR", 512, 0), ("BL", 0, 256), ("BR", 512, 256)):
        write_tga_rle(whole.crop((x, y, x + 512, y + 256)), prefix + name)
    print("  %s height (card units) %.1f" % (prefix, (box[3] - box[1]) * float(CARD_WIDTH)
                                             / (box[2] - box[0])))
    if prefix != "Card_":
        return

    portrait = lift_portrait(load(FRAME))
    write_tga_rle(portrait.resize((256, 256), Image.LANCZOS), "Portrait")
    print("  portrait frame (card units) %s" % (card_units(PORTRAIT_FRAME),))
    print("  portrait opening (card units) %s" % (card_units(PORTRAIT_OPENING),))


def write_portrait_background():
    glade = load(GLADE).convert("RGB")
    width, height = glade.size
    if float(width) / height > PORTRAIT_HOLE_ASPECT:
        cropped = int(round(height * PORTRAIT_HOLE_ASPECT))
        box = ((width - cropped) // 2, 0, (width - cropped) // 2 + cropped, height)
    else:
        cropped = int(round(width / PORTRAIT_HOLE_ASPECT))
        box = (0, (height - cropped) // 2, width, (height - cropped) // 2 + cropped)
    # One default backdrop for every theme but Classic, beside the shared
    # zone backdrops rather than inside a theme folder.
    path = os.path.join(os.path.dirname(OUTPUT), "UQ_Portrait_Background_Wide.tga")
    glade.crop(box).resize((256, 256), Image.LANCZOS).convert("RGBA").save(
        path, format="TGA", compression="tga_rle")
    print("%-28s %8d bytes" % (os.path.basename(path), os.path.getsize(path)))


def write_gossip_row():
    banner = load(BUTTON)
    banner = banner.crop(bounds(banner))
    width, height = banner.size
    left, top, right, bottom, radius = GOSSIP_INTERIOR
    # Drawn at 4x and reduced, so the cleared edge is antialiased.
    mask = Image.new("L", (width * 4, height * 4), 255)
    ImageDraw.Draw(mask).rounded_rectangle(
        (left * 4, top * 4, right * 4, bottom * 4), radius=radius * 4, fill=0)
    mask = mask.resize((width, height), Image.LANCZOS)
    alpha = Image.composite(banner.getchannel("A"), Image.new("L", banner.size, 0), mask)
    banner.putalpha(alpha)
    print("  Gossip_Frame cap texcoord %.4f" % (CAP_SHARE * height / width))
    write_tga_rle(banner.resize((512, 128), Image.LANCZOS), "Gossip_Frame")

    plank = load(PLANK)
    left, top, right, bottom = bounds(plank)
    left, top, right, bottom = left + 40, top + 14, right - 40, bottom - 14
    crop_height = int(round((right - left) / GOSSIP_WOOD_ASPECT))
    middle = (top + bottom) // 2
    wood = plank.crop((left, middle - crop_height // 2, right,
                       middle - crop_height // 2 + crop_height))
    write_tga_rle(wood.resize((512, 64), Image.LANCZOS), "Gossip_Wood")


def write_kicker():
    # The badges, drawn at 4x and reduced: a gold ring round a dark bronze
    # disc, a gold mark on it -- "!" for a quest to accept (Kicker_Icon), "?"
    # for one to turn in (Kicker_Icon_TurnIn).
    size = 256
    centre = size // 2
    gold = (246, 198, 84, 255)

    def badge():
        image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        draw = ImageDraw.Draw(image)
        draw.ellipse((6, 6, size - 6, size - 6), fill=(92, 56, 14, 255))
        draw.ellipse((16, 16, size - 16, size - 16), fill=(226, 172, 62, 255))
        draw.ellipse((30, 30, size - 30, size - 30), fill=(120, 76, 20, 255))
        draw.ellipse((40, 40, size - 40, size - 40), fill=(44, 26, 10, 255))
        return image, draw

    image, draw = badge()
    draw.rounded_rectangle((centre - 15, 70, centre + 15, 150), radius=12, fill=gold)
    draw.ellipse((centre - 16, 164, centre + 16, 196), fill=gold)
    write_tga_rle(image.resize((64, 64), Image.LANCZOS), "Kicker_Icon")

    # The "?": a hook (an arc open at its lower left, round caps) into a short
    # stem, then the same dot as the "!".
    image, draw = badge()
    stroke = 28
    hook = (centre - 36, 64, centre + 36, 136)
    draw.arc(hook, start=190, end=90, fill=gold, width=stroke)
    radius = (hook[2] - hook[0]) / 2.0 - stroke / 2.0
    for angle in (190, 90):
        import math
        x = centre + radius * math.cos(math.radians(angle))
        y = (hook[1] + hook[3]) / 2.0 + radius * math.sin(math.radians(angle))
        draw.ellipse((x - stroke / 2.0, y - stroke / 2.0, x + stroke / 2.0, y + stroke / 2.0),
                     fill=gold)
    draw.rounded_rectangle((centre - 14, 112, centre + 14, 152), radius=12, fill=gold)
    draw.ellipse((centre - 16, 164, centre + 16, 196), fill=gold)
    write_tga_rle(image.resize((64, 64), Image.LANCZOS), "Kicker_Icon_TurnIn")


def write_objective():
    """The objectives strip's rule, in two textures so neither is distorted:
    Objective_Line, a run of solid line the same in every column, so it
    stretches to any length unchanged and keeps full strength to its ends;
    and Objective_Diamond, square, drawn at its own aspect over the gap
    between the two runs (the diamond at 4x and reduced)."""
    ink = (120, 86, 48)
    line = Image.new("RGBA", (64, 8), ink + (0,))
    alpha = Image.new("L", (64, 8), 0)
    draw = ImageDraw.Draw(alpha)
    draw.rectangle((0, 3, 63, 4), fill=220)
    draw.rectangle((0, 2, 63, 2), fill=50)
    draw.rectangle((0, 5, 63, 5), fill=50)
    line.putalpha(alpha)
    write_tga_rle(line, "Objective_Line")

    size = 256
    c = size // 2
    diamond = Image.new("RGBA", (size, size), ink + (0,))
    alpha = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(alpha)
    draw.polygon(((c, 8), (size - 8, c), (c, size - 8), (8, c)), fill=255)
    draw.polygon(((c, 64), (size - 64, c), (c, size - 64), (64, c)), fill=0)
    diamond.putalpha(alpha)
    write_tga_rle(diamond.resize((32, 32), Image.LANCZOS), "Objective_Diamond")


def write_rows():
    plank = load(PLANK)
    plank = plank.crop(bounds(plank)).resize((512, 64), Image.LANCZOS)
    write_tga_rle(plank, "Row")

    # Warm glows over the plank, strongest at its centre line, clear at the
    # ends so the jagged caps keep their silhouette.
    def glow(red, green, blue, peak):
        image = Image.new("RGBA", (512, 64), (red, green, blue, 0))
        mask = Image.new("L", (512, 64), 0)
        ImageDraw.Draw(mask).rounded_rectangle((18, 8, 494, 56), radius=18, fill=peak)
        image.putalpha(mask.filter(ImageFilter.GaussianBlur(9)))
        return image
    write_tga_rle(glow(255, 200, 110, 55), "Row_Hover")
    write_tga_rle(glow(255, 176, 60, 90), "Row_Selected")


def tone_panel_parchment(panel):
    alpha = panel.getchannel("A")
    rgb = panel.convert("RGB")
    toned = ImageEnhance.Brightness(rgb).enhance(PANEL_PARCHMENT_BRIGHTNESS)
    toned = ImageEnhance.Contrast(toned).enhance(PANEL_PARCHMENT_CONTRAST)
    toned.putalpha(alpha)

    span = PANEL_PARCHMENT_MASK_LIGHT - PANEL_PARCHMENT_MASK_DARK
    mask = rgb.convert("L").point(
        lambda value: max(0, min(255,
            (value - PANEL_PARCHMENT_MASK_DARK) * 255 // span)))
    mask = ImageChops.multiply(mask, alpha)
    return Image.composite(toned, panel, mask)


def write_panel(preview_path=None):
    panel = load(PANEL)
    panel = panel.crop(bounds(panel))
    panel = tone_panel_parchment(panel)
    if preview_path:
        panel.save(preview_path)
    width, height = panel.size
    edge = PANEL_EDGE
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
        write_tga_rle(panel.crop(box).resize(size, Image.LANCZOS), "Panel_" + name)


def flag_rim(selected=False):
    size = FLAG_TEXTURE_SIZE
    rim = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    if selected:
        glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        ImageDraw.Draw(glow).rounded_rectangle(
            (3, 4, 61, 60), radius=9, outline=(255, 190, 45, 190), width=6)
        rim.alpha_composite(glow.filter(ImageFilter.GaussianBlur(2)))

    draw = ImageDraw.Draw(rim)
    if selected:
        draw.rounded_rectangle((4, 5, 60, 59), radius=8,
                               outline=(238, 171, 28, 255), width=4)
        draw.rounded_rectangle((7, 8, 57, 56), radius=6,
                               outline=(255, 228, 119, 255), width=2)
    else:
        draw.rounded_rectangle((4, 5, 60, 59), radius=8,
                               outline=(58, 27, 13, 255), width=3)
    return rim


def write_flags(preview_path=None):
    normal = flag_rim(False)
    selected = flag_rim(True)
    write_tga_rle(normal, "Flag")
    write_tga_rle(selected, "Flag_Selected")
    if preview_path:
        preview = Image.new("RGBA", (FLAG_TEXTURE_SIZE * 2, FLAG_TEXTURE_SIZE),
                            (0, 0, 0, 0))
        preview.alpha_composite(normal, (0, 0))
        preview.alpha_composite(selected, (FLAG_TEXTURE_SIZE, 0))
        preview.save(preview_path)


def write_plates():
    for source, name in ((PLATE, "Plate"), (PLATE_SELECTED, "Plate_Selected"),
                         (BUTTON, "Button")):
        banner = load(source)
        banner = banner.crop(bounds(banner))
        width, height = banner.size
        print("  %s cap texcoord %.4f" % (name, CAP_SHARE * height / width))
        write_tga_rle(banner.resize((512, 128), Image.LANCZOS), name)


def write_preview(card, path):
    """A mock-up at 2x card units with sample text, for checking the layout
    constants against the art. Never shipped."""
    scale = 2.0 * CARD_WIDTH / (CARD_BOX[2] - CARD_BOX[0])
    image = card.crop(CARD_BOX)
    image = image.resize((int(image.size[0] * scale), int(image.size[1] * scale)),
                         Image.LANCZOS)
    backdrop = Image.new("RGBA", image.size, (40, 52, 60, 255))
    backdrop.alpha_composite(image)
    draw = ImageDraw.Draw(backdrop)

    def rect(box, color):
        draw.rectangle(tuple(int(v * 2) for v in box), outline=color, width=2)
    layout = {
        "role": (48, 29.33, 488, 43.33),
        "speaker": (48, 43.33, 488, 71.33),
        "kickerIcon": (252, 91, 272, 111),
        "kicker": (278, 95, 338, 109),
        "title": (252, 115, 648, 143),
        "body": (248, 159, 648, 257),
        "page": (536, 95, 626, 109),
        "portraitHole": (57.4, 105.6, 221.9, 255.8),
        "portraitOpening": (60.4, 108.6, 218.9, 252.8),
    }
    for key, box in layout.items():
        rect(box, (220, 40, 40, 255) if key.startswith("portrait") else (30, 90, 200, 255))
    backdrop.convert("RGB").save(path)
    print("preview", path)


def main():
    if not os.path.isdir(OUTPUT):
        os.makedirs(OUTPUT)
    card = compose_card()
    write_card(card)
    write_card(compose_card(BODY_CUT_TALL), BODY_CUT_TALL, "CardTall_")
    write_objective()
    write_rows()
    preview = None
    if "--panel-preview" in sys.argv:
        preview = sys.argv[sys.argv.index("--panel-preview") + 1]
    write_panel(preview)
    flag_preview = None
    if "--flag-preview" in sys.argv:
        flag_preview = sys.argv[sys.argv.index("--flag-preview") + 1]
    write_flags(flag_preview)
    write_plates()
    write_kicker()
    write_portrait_background()
    write_gossip_row()
    if "--preview" in sys.argv:
        write_preview(card, sys.argv[sys.argv.index("--preview") + 1])


if __name__ == "__main__":
    main()
