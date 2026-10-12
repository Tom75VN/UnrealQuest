# Quest Log texture attribution

The three files in this folder draw UnrealQuest's standalone Quest Log -- the
Dragonflight-styled two-page spread used when unrealUI is not installed
(`Compatibility/ClientAPI.lua`, `Quest/StandaloneQuestLog.lua`).

They were copied byte-for-byte from unrealUI's `modern-wow` theme media
(`unrealUI/media/Textures/modern-wow/ui/`) so that the same interface is drawn
with or without that addon present. No pixel, dimension or colour was changed,
and nothing was cropped or recoloured: the measured geometry in ClientAPI.lua
was authored against these exact canvases.

| file | size | copied from | note |
| --- | --- | --- | --- |
| `QuestLogPageLeft.tga` | 896x896 | `ui/questlog-left-large-v2.tga` | The left and centre of the Quest Log spread: gold portrait ring, both parchment pages and the three drawn button beds along the bottom. The visible art ends at row 823; the rest of the canvas is transparent padding and is cropped by texture coordinates. |
| `QuestLogPageRight.tga` | 448x896 | `ui/questlog-right-large.tga` | The spread's outer right edge, including the recessed channel the details pane's scroll bar sits in. Visible art is the left 298 columns and the top 823 rows. |
| `QuestLogRedButton.tga` | 256x128 | `ui/red-button.tga` | Dragonflight octagonal button atlas: a 5x3 grid of 34x38 cells, first at (2,2), stepping 38 across and 40 down. Only the close column and the shared hover glow are drawn here, on the window's close button. |

## Origin and licence

The Dragonflight visual language these files belong to comes from
DragonflightUI (Guzruul; reforged by Stormhand), which ships **no LICENSE
file**, and part of that art derives from Blizzard UI assets. The two page
textures and the button atlas were supplied to unrealUI in this form by the
author and re-encoded there as 32-bit RLE TGA (image type 10, descriptor
0x08) -- the only addon texture form confirmed to render correctly at full
size on this client.

This import is by explicit decision of the author of both addons. It is not a
licence grant, it says nothing about redistribution rights, and this note must
stay with the files. It replaces the Extended QuestLog 3.6.1 parchment set
(Copyright 2006 Daniel Rehn) that this folder carried until UnrealQuest 0.3.6;
those files are no longer shipped or drawn.
