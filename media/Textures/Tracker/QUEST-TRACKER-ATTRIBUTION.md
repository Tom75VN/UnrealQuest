# Quest tracker texture attribution

`QuestTrackerSheet.tga` draws the chrome of both quest tracker windows
(`Compatibility/ClientAPI.lua`, `TrackerArt`). It is built from Blizzard's WoW
Forever objective tracker sheet, FileDataID 8268353 (UiTextureAtlas 4197,
build 1.60.1.69913), extracted with Forever FrameXML.

`tools/make_quest_tracker_art.py` converts the 1024x512 PNG into a 32-bit RLE
TGA (image type 10, descriptor 0x08), the client's proven addon sheet
encoding, with every pixel unchanged: no crop, resize, premultiplication,
repack or recolour. It decodes the written file again and aborts on any byte
of difference in any channel. It then checks that every drawn pixel lies in
one of the sheet's UiTextureAtlasMember boxes and that every box holds pixels,
and prints them all as `TrackerArt.pieces`. These are drawn:

| piece | atlas member |
| --- | --- |
| `header` | `UI-QuestTracker-Primary-Objective-Header` (trimmed to its visible pixels) |
| `zone` | `UI-QuestTracker-Secondary-Objective-Header` (trimmed to its visible pixels) |
| `zoneCollapse` / `zoneExpand` | `UI-QuestTrackerButton-Secondary-Collapse` / `-Expand` |
| `nub` | `UI-QuestTracker-Objective-Nub` |
| `check` | `UI-QuestTracker-Tracker-Check` |
| `goldLine` | `ui-questtracker-objfx_lineglow-c60` (the Minimal dialogue's header divider) |

The other 21 members (progress bar, glows, shine, fail mark, collapse/expand
and filter buttons with their pressed faces, highlights, quest item frame, LFG
eye) are in `TrackerArt.pieces` too but not drawn; the header's fold button
uses `plus-minus-button.tga` below instead. `8268353.png` is only the tool's
input and is never loaded by the client. It replaces `QuestTracker.tga`, the
halved, repacked 512x512 atlas this used to cut from the same sheet.

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
`media/Textures/QuestLog/QuestLogRedButton.tga`'s own shared hover-glow cell
(`media/Textures/QuestLog/ATTRIBUTION.md`), already imported for the standalone Quest
Log's close button. Additive blending is measured inert on this client
(`rendering.setblendmode_add_inert`), so it is drawn plain `BLEND` like every
other texture in this file and shown/hidden by the button's own
OnEnter/OnLeave rather than added as a bloom. Its size and placement copy
unrealUI's own game-settings menu exactly (`modules/modernwow.lua`
`mw.RedButtonGlow`, `M.modernWow.button128Red.glowMargin = -4`): a
TOPLEFT/BOTTOMRIGHT anchor inset from the button's own click area
(`TrackerArt.foldHoverMargin`), never a fixed added border.
