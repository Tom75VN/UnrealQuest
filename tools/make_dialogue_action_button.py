"""Build the Alliance V2 quest action button atlas from its authored sprite.

The sprite (`media/Textures/Dialogues/Alliance/buttons.png`, 1448x1086)
stacks four states of one button -- normal, hover, pressed, disabled -- each
with its chevron to the right. The three needed button faces and all four
chevrons are repacked into one 512x512 atlas:

    y 0, 106, 212        normal, pressed and disabled 512x104 button cells,
                         2 px apart so filtering never bleeds
    y 318                normal, hover, pressed and disabled 64x80 chevrons
                         at x 0, 66, 132, 198

Every button cell is cut from the same box relative to its own frame's top
edge, so the frame sits on the same texels in every state; every chevron cell
is centred on its own chevron. The cell layout is mirrored in
`Client.QUEST_DIALOGUE_ALLIANCE.ACTION_BUTTON` (Compatibility/ClientAPI.lua).

The Horde V2 sprite (`media/Textures/Dialogues/Horde/buttons.png`,
1122x1402) has the same four authored rows, repacked into
`UQ_Horde_Action_Button.tga`. Hover deliberately duplicates the normal
button and chevron pixels; `UQ_Horde_Action_Button_Hover.tga` supplies the
separate additive red bloom, so hover never moves the base art. The button
(spikes above and below) is too tall for four 512-wide cells in 512 px, so
the cells are narrower and the chevrons move to a column on the right:

    y 0, 127, 254, 381   four 410x125 button cells at x 0, 2 px apart
    x 420                four 80x96 chevron cells at y 0, 98, 196, 294

mirrored in `Client.QUEST_DIALOGUE_HORDE.ACTION_BUTTON`.

Alliance V2 hovers with `UQ_Alliance_Action_Button_Hover.tga`, the same
bloom tinted blue, drawn over the normal face while the atlas switches to its
dedicated hover chevron.

Horde light, Alliance light and Parchment share one red button built from
`media/Textures/QuestLog/128RedButton.tga` (the quest log's red atlas, 512x2048). Each state is
assembled the way the quest log draws it -- left cap from the short button,
the bar's middle stretched, the bar's own right cap -- at the source height,
then scaled into `UQ_Red_Action_Button.tga` (no chevron):

    y 0, 109, 218        normal, pressed and disabled 512x107 button cells

mirrored in `Client.QUEST_DIALOGUE_RED_ACTION_BUTTON`. Its hover is the
atlas's own red bloom cell, centred in `UQ_Red_Action_Button_Hover.tga`.

Alliance light keeps that simple geometry and steel bevel, but its saturated
red pixels are hue-shifted and brightened to the theme's cobalt blue. The
matching atlas and bloom are written as
`AllianceLight/UQ_AllianceLight_Action_Button*.tga`.

Run from the addon root:  python tools/make_dialogue_action_button.py
"""

import colorsys
import os

from PIL import Image, ImageChops, ImageDraw, ImageFilter


ROOT = os.getcwd()
OUTPUT = os.path.join(ROOT, "media", "Textures", "Dialogues", "Alliance")
SPRITE = os.path.join(OUTPUT, "buttons.png")
TARGET = os.path.join(OUTPUT, "UQ_Alliance_Action_Button.tga")
HOVER_TARGET = os.path.join(OUTPUT, "UQ_Alliance_Action_Button_Hover.tga")

ATLAS = 512
# Measured on SPRITE (alpha > 128): the frame's top edge of each state row
# and the centre of each state's chevron.
FRAME_TOPS = (55, 309, 566, 817)
CHEVRON_CENTRES = ((1322, 156), (1320, 409), (1320, 664), (1322, 916))
# The button box: the frame plus its glow, and the notch under it.
BUTTON_LEFT, BUTTON_RIGHT = 44, 1220
BUTTON_ABOVE, BUTTON_HEIGHT = 6, 239
CHEVRON_SIZE = (147, 184)

BUTTON_CELL = (512, 104)
BUTTON_PITCH = 106
CHEVRON_CELL = (64, 80)
CHEVRON_PITCH = 66
CHEVRON_TOP = 3 * BUTTON_PITCH
BUTTON_STATES = (0, 2, 3)
STATE_BRIGHTNESS = (0.84, 1.0, 1.0, 1.0)


def pixels(image):
    if hasattr(image, "get_flattened_data"):
        return image.get_flattened_data()
    return image.getdata()


def adjust_brightness(image, factor):
    if factor == 1.0:
        return image
    red, green, blue, alpha = image.split()
    lut = [min(255, int(round(value * factor))) for value in range(256)]
    return Image.merge("RGBA", (red.point(lut), green.point(lut),
                                blue.point(lut), alpha))


def build():
    sprite = Image.open(SPRITE).convert("RGBA")
    atlas = Image.new("RGBA", (ATLAS, ATLAS), (0, 0, 0, 0))
    for output_state, source_state in enumerate(BUTTON_STATES):
        top = FRAME_TOPS[source_state] - BUTTON_ABOVE
        button = sprite.crop((BUTTON_LEFT, top, BUTTON_RIGHT, top + BUTTON_HEIGHT))
        button = button.resize(BUTTON_CELL, Image.LANCZOS)
        button = adjust_brightness(button, STATE_BRIGHTNESS[source_state])
        atlas.alpha_composite(button, (0, output_state * BUTTON_PITCH))
    for state in range(4):
        x, y = CHEVRON_CENTRES[state]
        width, height = CHEVRON_SIZE
        chevron = sprite.crop((x - width // 2, y - height // 2,
                               x - width // 2 + width, y - height // 2 + height))
        atlas.alpha_composite(chevron.resize(CHEVRON_CELL, Image.LANCZOS),
                              (state * CHEVRON_PITCH, CHEVRON_TOP))
    return atlas


HORDE_OUTPUT = os.path.join(ROOT, "media", "Textures", "Dialogues", "Horde")
HORDE_SPRITE = os.path.join(HORDE_OUTPUT, "buttons.png")
HORDE_TARGET = os.path.join(HORDE_OUTPUT, "UQ_Horde_Action_Button.tga")
HORDE_HOVER_TARGET = os.path.join(
    HORDE_OUTPUT, "UQ_Horde_Action_Button_Hover.tga")
# Measured on HORDE_SPRITE (alpha > 200): the left spike's tip row of each
# state, which every state's box hangs from, and the centre of each chevron
# (alpha > 128). The box spans the side spikes (x 15..908), the top spike and
# the hover glow (127..131 px above the tip) and the bottom spike (137 below).
HORDE_TIPS = (225, 519, 822, 1121)
HORDE_CHEVRON_CENTRES = ((992, 232), (992, 522), (990, 819), (990, 1119))
HORDE_LEFT, HORDE_RIGHT = 9, 915
HORDE_ABOVE, HORDE_HEIGHT = 135, 276
HORDE_CHEVRON_SIZE = (132, 158)

HORDE_BUTTON_CELL = (410, 125)
HORDE_BUTTON_PITCH = 127
HORDE_CHEVRON_CELL = (80, 96)
HORDE_CHEVRON_LEFT = 420
HORDE_CHEVRON_PITCH = 98


def build_horde():
    if os.path.exists(HORDE_SPRITE):
        sprite = Image.open(HORDE_SPRITE).convert("RGBA")
        atlas = Image.new("RGBA", (ATLAS, ATLAS), (0, 0, 0, 0))
        for state in range(4):
            source_state = 0 if state == 1 else state
            top = HORDE_TIPS[source_state] - HORDE_ABOVE
            button = sprite.crop((HORDE_LEFT, top, HORDE_RIGHT, top + HORDE_HEIGHT))
            atlas.alpha_composite(button.resize(HORDE_BUTTON_CELL, Image.LANCZOS),
                                  (0, state * HORDE_BUTTON_PITCH))
            x, y = HORDE_CHEVRON_CENTRES[source_state]
            width, height = HORDE_CHEVRON_SIZE
            chevron = sprite.crop((x - width // 2, y - height // 2,
                                   x - width // 2 + width, y - height // 2 + height))
            atlas.alpha_composite(chevron.resize(HORDE_CHEVRON_CELL, Image.LANCZOS),
                                  (HORDE_CHEVRON_LEFT, state * HORDE_CHEVRON_PITCH))
    else:
        atlas = Image.open(HORDE_TARGET).convert("RGBA")
        normal_button = atlas.crop((0, 0, HORDE_BUTTON_CELL[0], HORDE_BUTTON_CELL[1]))
        normal_chevron = atlas.crop((HORDE_CHEVRON_LEFT, 0,
                                     HORDE_CHEVRON_LEFT + HORDE_CHEVRON_CELL[0],
                                     HORDE_CHEVRON_CELL[1]))
        atlas.paste(normal_button, (0, HORDE_BUTTON_PITCH))
        atlas.paste(normal_chevron,
                    (HORDE_CHEVRON_LEFT, HORDE_CHEVRON_PITCH))
    return atlas


def build_hover(colour):
    outer = Image.new("L", (ATLAS, 128), 0)
    ImageDraw.Draw(outer).rounded_rectangle(
        (72, 42, 440, 86), radius=22, fill=170)
    outer = outer.filter(ImageFilter.GaussianBlur(18))
    core = Image.new("L", (ATLAS, 128), 0)
    ImageDraw.Draw(core).rounded_rectangle(
        (96, 50, 416, 78), radius=14, fill=255)
    core = core.filter(ImageFilter.GaussianBlur(10))
    alpha = ImageChops.lighter(outer, core)
    glow = Image.new("RGBA", alpha.size, colour + (0,))
    glow.putalpha(alpha)
    return glow


RED_OUTPUT = os.path.join(ROOT, "media", "Textures", "Dialogues")
RED_SOURCE = os.path.join(ROOT, "media", "Textures", "QuestLog", "128RedButton.tga")
RED_TARGET = os.path.join(RED_OUTPUT, "UQ_Red_Action_Button.tga")
RED_HOVER_TARGET = os.path.join(RED_OUTPUT, "UQ_Red_Action_Button_Hover.tga")
ALLIANCE_LIGHT_OUTPUT = os.path.join(RED_OUTPUT, "AllianceLight")
ALLIANCE_LIGHT_TARGET = os.path.join(
    ALLIANCE_LIGHT_OUTPUT, "UQ_AllianceLight_Action_Button.tga")
ALLIANCE_LIGHT_HOVER_TARGET = os.path.join(
    ALLIANCE_LIGHT_OUTPUT, "UQ_AllianceLight_Action_Button_Hover.tga")
# The source button's red face is much darker than Alliance Light's cobalt
# rails. Lift only the saturated pixels that are hue-shifted; steel, neutral
# disabled pixels, geometry and alpha remain untouched.
ALLIANCE_LIGHT_VALUE_SCALE = 1.25
ALLIANCE_LIGHT_VALUE_LIFT = 0.06
# Measured on RED_SOURCE (alpha > 8), as Compatibility/ClientAPI.lua's
# QuestLogSkin reads it: 291 px bars whose right end carries the bevel, and
# 114 px short buttons whose left end does, all 125 px tall. Normal, pressed
# (the recessed row) and disabled (the grey row), in atlas order.
RED_STATES = (
    {"bar": 523, "cap_left": 392, "cap_top": 913},
    {"bar": 783, "cap_left": 378, "cap_top": 1043},
    {"bar": 653, "cap_left": 262, "cap_top": 1043},
)
RED_BAR_WIDTH = 291
RED_SOURCE_HEIGHT = 125
RED_CAP = 28
# Assembled 600 px wide, then scaled to the cell: a 4.79 aspect.
RED_ASSEMBLED_WIDTH = 600
RED_BUTTON_CELL = (512, 107)
RED_BUTTON_PITCH = 109
# The bloom cell under the bars (15..423 x 418..489).
RED_GLOW_BOX = (15, 418, 424, 490)


def build_red():
    source = Image.open(RED_SOURCE).convert("RGBA")
    atlas = Image.new("RGBA", (ATLAS, ATLAS), (0, 0, 0, 0))
    middle_width = RED_ASSEMBLED_WIDTH - 2 * RED_CAP
    for index, state in enumerate(RED_STATES):
        bar_top, cap_top = state["bar"], state["cap_top"]
        left = source.crop((state["cap_left"], cap_top,
                            state["cap_left"] + RED_CAP, cap_top + RED_SOURCE_HEIGHT))
        middle = source.crop((RED_CAP, bar_top, RED_BAR_WIDTH - RED_CAP,
                              bar_top + RED_SOURCE_HEIGHT))
        right = source.crop((RED_BAR_WIDTH - RED_CAP, bar_top, RED_BAR_WIDTH,
                             bar_top + RED_SOURCE_HEIGHT))
        button = Image.new("RGBA", (RED_ASSEMBLED_WIDTH, RED_SOURCE_HEIGHT), (0, 0, 0, 0))
        button.paste(left, (0, 0))
        button.paste(middle.resize((middle_width, RED_SOURCE_HEIGHT), Image.LANCZOS),
                     (RED_CAP, 0))
        button.paste(right, (RED_ASSEMBLED_WIDTH - RED_CAP, 0))
        atlas.alpha_composite(button.resize(RED_BUTTON_CELL, Image.LANCZOS),
                              (0, index * RED_BUTTON_PITCH))
    return atlas


def build_red_hover():
    source = Image.open(RED_SOURCE).convert("RGBA")
    glow = source.crop(RED_GLOW_BOX)
    image = Image.new("RGBA", (ATLAS, 128), (0, 0, 0, 0))
    image.alpha_composite(glow, ((ATLAS - glow.size[0]) // 2, (128 - glow.size[1]) // 2))
    return image


def alliance_blue(image):
    output = Image.new("RGBA", image.size, (0, 0, 0, 0))
    converted = []
    for red, green, blue, alpha in pixels(image):
        hue, saturation, value = colorsys.rgb_to_hsv(
            red / 255.0, green / 255.0, blue / 255.0)
        if saturation > 0.25 and (hue < 0.10 or hue > 0.94):
            value = min(1.0, value * ALLIANCE_LIGHT_VALUE_SCALE
                        + ALLIANCE_LIGHT_VALUE_LIFT)
            red, green, blue = (
                int(round(channel * 255.0))
                for channel in colorsys.hsv_to_rgb(
                    0.625, max(0.72, saturation), value))
        converted.append((red, green, blue, alpha))
    output.putdata(converted)
    return output


def save(target, image):
    image.save(target, format="TGA", compression="tga_rle")
    with open(target, "rb") as handle:
        header = handle.read(18)
    if len(header) != 18 or header[2] != 10 or header[16] != 32 or header[17] != 8:
        raise ValueError("action button texture is not a 32-bit RLE type-10 TGA: " + target)
    print("%-40s %s" % (os.path.basename(target), image.size))


def main():
    # A theme whose authored sprite is not on disk keeps its shipped textures.
    if os.path.exists(SPRITE):
        save(TARGET, build())
    else:
        print("skipped (no sprite): " + SPRITE)
    save(HOVER_TARGET, build_hover((40, 140, 255)))
    if os.path.exists(HORDE_SPRITE) or os.path.exists(HORDE_TARGET):
        save(HORDE_TARGET, build_horde())
        save(HORDE_HOVER_TARGET, build_hover((255, 24, 0)))
    else:
        print("skipped (no sprite): " + HORDE_SPRITE)
    red = build_red()
    red_hover = build_red_hover()
    save(RED_TARGET, red)
    save(RED_HOVER_TARGET, red_hover)
    save(ALLIANCE_LIGHT_TARGET, alliance_blue(red))
    save(ALLIANCE_LIGHT_HOVER_TARGET, alliance_blue(red_hover))


if __name__ == "__main__":
    main()
