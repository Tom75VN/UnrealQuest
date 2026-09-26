# Quest tracker texture attribution

`QuestTracker.tga` draws the chrome of both quest tracker windows
(`Compatibility/ClientAPI.lua`, `TrackerArt`). It is built from Blizzard's WoW
Forever objective tracker sheet, FileDataID 8268353 (UiTextureAtlas 4197,
build 1.60.1.69913), extracted with Forever FrameXML.

`tools/make_quest_tracker_art.py` cuts these UiTextureAtlasMember regions from
the 1024x512 sheet, trims the two header bars to their visible pixels, halves
every piece to the interface's own scale with premultiplied alpha, and packs
them into a 512x512 32-bit RLE TGA (image type 10, descriptor 0x08), the
client's proven addon atlas form:

| piece | atlas member |
| --- | --- |
| `header` | `UI-QuestTracker-Primary-Objective-Header` |
| `zone` | `UI-QuestTracker-Secondary-Objective-Header` |
| `collapse` / `expand` | `UI-QuestTrackerButton-Collapse-All` / `-Expand-All` |
| `highlight` | `UI-QuestTrackerButton-Red-Highlight` |
| `zoneCollapse` / `zoneExpand` | `UI-QuestTrackerButton-Secondary-Collapse` / `-Expand` |
| `nub` | `UI-QuestTracker-Objective-Nub` |
| `check` | `UI-QuestTracker-Tracker-Check` |

The `collapse`, `expand` and `highlight` pieces are still packed but no longer
drawn: the header's fold button now uses `plus-minus-button.tga` below
instead. No pixel was recoloured. The sheet itself (`8268353.png`) is only the
tool's input and is never loaded by the client.

## `plus-minus-button.tga`

| file | size | copied from | members used |
| --- | --- | --- | --- |
| `plus-minus-button.tga` | 64x64 | `unrealUI/media/Textures/modern-wow/buttons/plus-minus-button.tga` | `plusNormal` (2..22 x 0..22) and `minusNormal` (2..22 x 24..46) |

Blizzard's plus/minus tree button, FileDataID 4496242. unrealUI's own copy
(`media/Textures/modern-wow/ATTRIBUTION.md`) converted it from the PNG kept
beside it: RGBA PNG to 32-bit uncompressed bottom-up TGA, pixels unchanged.
Copied here byte-for-byte (user request, 2026-09-27) for the header's fold
button, literal "+" while the tracker body is folded away and "-" while it is
shown, replacing the settings dropdown button faces this used before. The
right column (pushed) is not wired: a pressed face needs OnMouseDown /
OnMouseUp, which have no runtime record on this client.

The hover glow behind the glyph is not a new file: it reuses
`media/QuestLog/QuestLogRedButton.tga`'s own shared hover-glow cell
(`media/QuestLog/ATTRIBUTION.md`), already imported for the standalone Quest
Log's close button. Additive blending is measured inert on this client
(`rendering.setblendmode_add_inert`), so it is drawn plain `BLEND` like every
other texture in this file and shown/hidden by the button's own
OnEnter/OnLeave rather than added as a bloom. Its size and placement copy
unrealUI's own game-settings menu exactly (`modules/modernwow.lua`
`mw.RedButtonGlow`, `M.modernWow.button128Red.glowMargin = -4`): a
TOPLEFT/BOTTOMRIGHT anchor inset from the button's own click area
(`TrackerArt.foldHoverMargin`), never a fixed added border.
