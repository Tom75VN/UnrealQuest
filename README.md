<p align="center"><img src="screenshots/logo.webp" alt="UnrealQuest logo" width="160"></p>

<h1 align="center">UnrealQuest</h1>

<p align="center"><b>See every objective. Spend less time searching. Adventure more.</b></p>

<p align="center">Built from scratch for the <b>Unreal Azeroth / Emberveil</b> client -- not a fork or a port.</p>

> [!IMPORTANT]
> ## Install
>
> 1. [Download the latest release](https://github.com/Tom75VN/UnrealQuest/releases/latest/download/UnrealQuest.zip).
> 2. Extract it into `Azeroth\Interface\AddOns\`.
> 3. Check that `UnrealQuest.toc` sits directly inside the `unrealQuest` folder.
> 4. Launch the game, or reload the interface.

![World map with quest areas, numbered quests and the tracker window](screenshots/world-map-areas-dots-tracker.jpg)

## Features at a glance

| | |
|---|---|
| [World map](#world-map) | Objective dots and areas, numbered quests, `!` / `?` markers, patrol paths, any zone |
| [Minimap](#minimap) | The same quest pins and areas around you, with tooltips |
| [Quest tracker](#quest-tracker) | Movable, resizable, unlimited, grouped by zone, live progress |
| [Quest navigator](#quest-navigator) | An on-screen arrow to the next objective, plus a second one for a tracked creature |
| [Immersive quest dialogue](#immersive-quest-dialogue) | Six themes, keyboard control, optional auto accept and hand-in |
| [Quest log](#quest-log) | Two full-height pages, Show / Track / Follow, levels, translations |
| [Rewards](#rewards) | Experience, reputation, best upgrade and best sale value |
| [Recognize quest targets](#recognize-quest-targets) | Tooltips, nameplate numbers, target-frame icon, raid marks |
| [Explore the world](#explore-the-world) | NPC finder, herbs and veins, chests, rares, dungeons, quest vendors |
| [Rare alert](#rare-alert) | A warning card and sound near a rare, elite or boss spawn |
| [Party](#party) | Shared-quest count and objective progress in party chat |
| [Languages](#languages) | English, French, Russian and Simplified Chinese |

## World map

Turn the world map into a questing compass.

- **Dots, areas or both** for every objective, each quest in its own colour that survives a relog.
- **Numbered quests** that match the tracker; a finished quest's number turns green.
- **`!` and `?` markers** for quests to take and to hand in; the `?` turns orange when the quest is ready.
- **Followed quest** stands out with a gold outline and a ring that pulses on its turn-in.
- **Hover a pin** to fade every other quest and light up that quest's turn-in.
- **Patrol paths** for moving quest NPCs, elites and vendors.
- **One tooltip for stacked pins**, listing every quest that shares a spawn.
- **Click a pin to follow its quest**; shift-click a `!` to mark a quest as done.
- **Any zone, not just yours** -- and Show (or ctrl-click in the tracker) opens the zone you actually need, across continents.
- **Cleaner map**: no other-faction givers, no profession quests you cannot do, no city guards or dungeon interiors.

![Quest areas on the world map with the tracker window](screenshots/world-map-areas-tracker.jpg)

<table>
<tr>
<td width="50%"><img src="screenshots/world-map-followed-quest-dots.jpg" alt="Followed quest dots outlined in gold"><br><sub>The followed quest's dots and turn-in ring</sub></td>
<td width="50%"><img src="screenshots/world-map-shared-objective-tooltip.jpg" alt="One tooltip for two quests sharing a spawn"><br><sub>Two quests on the same spawn, one tooltip</sub></td>
</tr>
<tr>
<td><img src="screenshots/world-map-elite-patrol.jpg" alt="Elite patrol path on the world map"><br><sub>Patrol path of a roaming elite</sub></td>
<td><img src="screenshots/settings-map-objective-style.jpg" alt="Map style options"><br><sub>Areas, dots, or both</sub></td>
</tr>
</table>

## Minimap

Nearby objectives, givers and turn-ins stay on the minimap while you move.

- The world map's dots and areas, drawn around you.
- A tooltip on every pin; click a pin to follow its quest.
- Off-screen `!` and `?` markers can stick to the edge, and your own arrow stays on top.
- Hover a quest in the tracker to enlarge its dots.

<p align="center"><img src="screenshots/minimap-areas-dots.jpg" alt="Quest area and objective dots on the minimap" width="340"></p>

## Quest tracker

Every quest you need, in one movable window.

- **No five-quest limit**, grouped by zone, with live objective progress and quest levels.
- **Drag and resize** it; its position and tracked quests survive a reload.
- **Current zone only** -- including quests whose objectives are here but that the log files elsewhere, and dungeons.
- Optional progress bars, a hide-until-started filter, and fold / unfold per quest and zone.
- Elite and dungeon quests show a `+` after their level (`[11+]`).
- The followed quest glows gold; click a quest to follow it.
- The same tracker is shown on the world map.

<p align="center"><img src="screenshots/tracker-followed-quest.jpg" alt="Tracker rows with the followed quest highlighted" width="420"></p>

## Quest navigator

An arrow that tells you which way to turn.

- Points at the nearest objective of the followed quest -- or of any quest nearby when you follow none -- and switches to the turn-in once the quest is done.
- Shows the distance and an estimated travel time; it fades as the target moves behind you.
- Drag it anywhere; its position is saved.
- **Mob tracking**: search the creature database, track one creature, and a second arrow leads you to its nearest spawn while its spawns appear on both maps.

<table>
<tr>
<td width="33%"><img src="screenshots/navigator-straight-ahead.jpg" alt="Navigator pointing straight ahead"><br><sub>Straight ahead</sub></td>
<td width="33%"><img src="screenshots/navigator-behind.jpg" alt="Navigator pointing behind"><br><sub>Behind you</sub></td>
<td width="33%"><img src="screenshots/mob-navigator.jpg" alt="Mob navigator naming the tracked creature"><br><sub>Tracked creature</sub></td>
</tr>
</table>

![Mob tracking search and results](screenshots/settings-mob-tracking.jpg)

## Immersive quest dialogue

A replacement for the stock gossip and quest windows, with the NPC's portrait, paginated text, objectives and rewards.

- **Six themes**: Minimal, Parchment, Alliance, Horde, Alliance light and Horde light.
- **Conversation card** for gossip and greetings, **quest card** for offers, progress and rewards.
- **Keyboard control** (Space to accept, Esc to decline) and an option to hide the interface while talking.
- **Auto accept and complete** (off by default): quests are accepted and handed in for you; a choice of rewards is left to you.
- Language flags on every quest card to read that quest in another language.

<table>
<tr>
<td width="50%"><img src="screenshots/dialogue-alliance-quest.jpg" alt="Alliance dialogue theme"><br><sub>Alliance</sub></td>
<td width="50%"><img src="screenshots/dialogue-horde-quest.jpg" alt="Horde dialogue theme"><br><sub>Horde</sub></td>
</tr>
<tr>
<td><img src="screenshots/dialogue-alliance-light-quest.jpg" alt="Alliance light dialogue theme"><br><sub>Alliance light</sub></td>
<td><img src="screenshots/dialogue-horde-light-quest.jpg" alt="Horde light dialogue theme"><br><sub>Horde light</sub></td>
</tr>
<tr>
<td><img src="screenshots/dialogue-parchment-quest.jpg" alt="Parchment dialogue theme"><br><sub>Parchment</sub></td>
<td><img src="screenshots/dialogue-minimal-quest.jpg" alt="Minimal dialogue theme"><br><sub>Minimal</sub><br><br><img src="screenshots/dialogue-minimal-greeting.jpg" alt="Minimal greeting with quest choices"><br><sub>Minimal greeting</sub></td>
</tr>
</table>

![Horde conversation card](screenshots/dialogue-horde-conversation.jpg)

## Quest log

- **Two full-height pages**: the quest list on the left, the selected quest on the right (standalone and with unrealUI's Classic WoW theme; unrealUI's modern themes keep their own layout).
- **Show, Track and Follow** buttons on every quest.
- Quest levels, difficulty colours, and unlimited tracking from the log.
- **Language flags** to read one quest's title, objectives and description in another language.
- In a party, how many members share each quest.

![Two-page quest log](screenshots/quest-log-two-page.jpg)

<table>
<tr>
<td width="50%"><img src="screenshots/quest-log-language-flags.jpg" alt="Language flags on a quest"><br><sub>Per-quest language flags</sub></td>
<td width="50%"><img src="screenshots/quest-log-party-shared-count.jpg" alt="Party members sharing each quest"><br><sub>Party members on the same quest</sub></td>
</tr>
</table>

## Rewards

- **Experience and reputation** on the quest log, the offer window and the turn-in window.
- **Gear advisor**: a green arrow on the best upgrade, yellow on the runner-up, red on a downgrade, and a coin on the reward that sells for the most.
- Reward names drawn in their item quality colour.

<table>
<tr>
<td width="50%"><img src="screenshots/rewards-gear-advisor.jpg" alt="Gear advisor marks on quest rewards"><br><sub>Best sale value and upgrades</sub></td>
<td width="50%"><img src="screenshots/rewards-experience-reputation.jpg" alt="Experience and reputation rewards"><br><sub>Experience and reputation</sub></td>
</tr>
</table>

## Recognize quest targets

- **Creature tooltips** show the quest, your live progress and the item drop rate.
- **Respawn time** from the world data on creature and object tooltips.
- **Map tooltips** for bosses and elites list their loot with drop rates, with item comparison.
- **Nameplate number**: the quest's number next to a creature an objective still needs.
- **Target frame icon** while your target is a quest creature (unrealUI target frame).
- **Raid marks** over quest creatures (optional).

<table>
<tr>
<td width="33%"><img src="screenshots/tooltip-quest-progress-drop-rate.jpg" alt="Quest progress and drop rate in a creature tooltip"><br><sub>Progress and drop rate</sub></td>
<td width="33%"><img src="screenshots/nameplate-quest-number.jpg" alt="Quest number beside a nameplate"><br><sub>Nameplate quest number</sub></td>
<td width="33%"><img src="screenshots/target-frame-quest-icon.jpg" alt="Quest icon on the target frame"><br><sub>Target frame icon</sub></td>
</tr>
<tr>
<td><img src="screenshots/tooltip-respawn-time.jpg" alt="Respawn time in a tooltip"><br><sub>Respawn time</sub></td>
<td colspan="2"><img src="screenshots/world-map-loot-tooltip-item-compare.jpg" alt="Elite loot table on the world map with item comparison"><br><sub>Loot and drop rates on the map</sub></td>
</tr>
</table>

## Explore the world

Everything is picked from the tracker's spyglass menu and shown on both maps.

- **NPC finder**: auctioneers, bankers, battlemasters, flight masters, innkeepers, mailboxes, vendors and your class trainer.
- **Gathering**: treasure chests, fishing pools, and herbs and veins, each with its own icon and required skill.
- **Rare, elite and boss** creatures with a silver, gold or red star.
- **Dungeon and raid entrances** with their level range and required level.
- **Quest vendors**: when a quest needs an item a trader sells, the sellers are marked until you own it.

<table>
<tr>
<td width="33%"><img src="screenshots/npc-finder.jpg" alt="NPC finder menu"><br><sub>NPC finder</sub></td>
<td width="33%"><img src="screenshots/world-map-gathering-nodes.jpg" alt="Herbs and mining veins on the map"><br><sub>Herbs and veins</sub></td>
<td width="33%"><img src="screenshots/world-map-rare-elite-boss-stars.jpg" alt="Rare, elite and boss stars"><br><sub>Rare, elite and boss</sub></td>
</tr>
<tr>
<td><img src="screenshots/world-map-dungeon-level-range.jpg" alt="Dungeon entrance with level range"><br><sub>Dungeon entrance</sub></td>
<td><img src="screenshots/world-map-raid-entrance.jpg" alt="Raid entrance"><br><sub>Raid entrance</sub></td>
<td><img src="screenshots/world-map-vendor-patrol.jpg" alt="Vendors on the map"><br><sub>Vendors</sub></td>
</tr>
</table>

## Rare alert

- A movable card when you come near a known rare, rare elite or boss spawn, with its rank, level, distance, direction and your kill count.
- Separate switches for rares, elites and bosses, an alert distance, and a sound you choose.

<table>
<tr>
<td width="60%"><img src="screenshots/rare-alert-card.jpg" alt="Rare creature alert card"></td>
<td width="40%"><img src="screenshots/settings-rare-alert-filter.jpg" alt="Rare alert settings"></td>
</tr>
</table>

## Party

- Report your objective progress to the party, one line per step -- only for quests another member also has (off by default).
- Option to report completed objectives only.

![Objective progress in party chat](screenshots/party-objective-announce.jpg)

## Languages

- The interface ships in **English, French, Russian and Simplified Chinese**, picked with the flags in the settings window.
- With unrealUI installed, UnrealQuest follows unrealUI's language instead.
- Quest, creature and zone **names** follow your client's language, to match what the game shows.
- Quests themselves can be read in another language, one quest at a time, from the quest log and dialogue flags.

## Settings and commands

- A standalone settings window (General, Quest dialogue and Mob tracking tabs) that becomes an "UnrealQuest" entry in unrealUI's settings when it is installed.
- A settings button beside the minimap.
- **pfQuest import**: bring in pfQuest's completed-quest history so finished quests stay off the map; it can be undone.

| Command | What it does |
|---|---|
| `/uq` | List every command |
| `/uq config` | Open the settings |
| `/uq tracker on\|off\|reset` | Show, hide or reset the tracker |
| `/uq map dots\|areas\|both` | Choose how objectives are drawn |
| `/uq track <quest>` / `/uq untrack <quest>` | Track or untrack a quest |
| `/uq hide <quest>` / `/uq unhide <quest>` | Hide or restore a quest's map pins |
| `/uq marks on\|off` | Raid marks over quest creatures |
| `/uq pfquest import` | Import pfQuest's quest history |
| `/uq status` | What this build detected about the client |

## Version

Current release: **0.5.2**

## License

UnrealQuest is released under the MIT License. Bundled world data originates from VMaNGOS and was packaged by pfQuest under the MIT License. Imported artwork keeps its own provenance; see [LICENSE](LICENSE), [Database/CREDITS.md](Database/CREDITS.md) and [media/Textures/QuestLog/ATTRIBUTION.md](media/Textures/QuestLog/ATTRIBUTION.md).
