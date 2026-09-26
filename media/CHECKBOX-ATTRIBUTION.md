# Checkbox texture attribution

`checkbox-modern.tga` draws the "Show all areas" checkbox in the world map's
quest tracker header (`Client.CreateTrackerAreaToggle` in
`Compatibility/ClientAPI.lua`).

It was copied byte-for-byte from unrealUI's
`media/Textures/forever-wow/settings/checkmark-minimal.tga`, the sheet
unrealUI's Modern WoW settings draw their checkboxes from, so the same control
is drawn with or without that addon present.

| file | size | copied from | members used |
| --- | --- | --- | --- |
| `checkbox-modern.tga` | 64x64 | `forever-wow/settings/checkmark-minimal.tga` (FileDataID 4614134) | `checkbox-minimal` (1..31 x 1..30), the box; `checkmark-minimal` (1..31 x 32..61), the tick |

## Origin

Blizzard Entertainment UI art from WoW Forever build 1.60.1.69913
(`Blizzard_Settings_Shared`, `SettingsCheckboxTemplate`), converted by
unrealUI from PNG to RLE-compressed 32-bit TGA (origin bottom-left,
descriptor 0x08) with no pixel changed. See unrealUI's
`media/Textures/forever-wow/ATTRIBUTION.md` for the full provenance.

It is imported as interoperability reference for a client-side interface
reimplementation, by explicit decision of the author of both addons. This is
not a licence grant, and this note must stay with the file.
