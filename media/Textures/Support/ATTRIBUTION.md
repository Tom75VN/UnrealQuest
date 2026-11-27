# Support popup texture attribution

These two sheets draw the support reminder popup
(`Client.CreateSupportPopup` in `Compatibility/ClientAPI.lua`,
`Core/SupportPopup.lua`). Its checkbox uses `../Settings/checkbox-modern.tga`
(see `CHECKBOX-ATTRIBUTION.md` there).

| file | size | copied from | use |
| --- | --- | --- | --- |
| `unrealquest-support-metal.tga` | 512x2048 | unrealMap `Media/Textures/UI/unrealmap-popup-metal.tga` = unrealUI `media/Textures/modern-wow/ui/character-create-diamond-metal.tga` | diamond-metal housing, cells from UnrealUI `M.modernWow.metalFrame` |
| `unrealquest-support-button.tga` | 512x2048 | unrealMap `Media/Textures/UI/unrealmap-popup-button.tga` = unrealUI `media/Textures/modern-wow/buttons/128RedButton.tga` | red button three-slice, pressed row and hover glow, cells from UnrealUI `M.modernWow.button128Red` |

Copied byte-for-byte and renamed to unique basenames, because this client
resolves addon textures by basename (`textures.addon_paths_resolved_by_basename`).

## Origin

DragonflightUI-Reforged 1.3.4 (`CharacterCreateDiamondMetal8x.PNG`,
`128RedButton.tga`), converted by unrealUI to RLE-compressed 32-bit TGA. See
unrealUI's `media/Textures/modern-wow/ATTRIBUTION.md` for the full provenance.

DragonflightUI-Reforged ships no LICENSE file and part of the art derives from
Blizzard UI assets. Imported as interoperability reference by explicit decision
of the author of these addons. This is not a licence grant, and this note must
stay with the files.
