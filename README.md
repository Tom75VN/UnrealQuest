# UnrealQuest

See every objective. Spend less time searching. Adventure more.

**Developed from scratch exclusively for the Unreal Azeroth / Emberveil client — not a fork or port.**

> [!IMPORTANT]
> ## Install UnrealQuest
>
> 1. [Download the latest release](https://github.com/Tom75VN/UnrealQuest/releases/latest/download/UnrealQuest.zip).
> 2. Extract the archive into `Azeroth\Interface\AddOns\`.
> 3. Confirm that `UnrealQuest.toc` is directly inside the `unrealQuest` folder.
> 4. Launch the game or reload the interface.

UnrealQuest turns questing into exploration instead of guesswork. It is designed and optimized specifically for Unreal Azeroth / Emberveil, with every feature built around the client you actually play.

## Main benefits

- Enjoy a quest helper purpose-built for Unreal Azeroth instead of adapted from another client.
- See active quest objectives as clear blue areas directly on your world map.
- Discover available quests with `!` markers and find turn-in locations with `?` markers.
- Follow nearby quest creatures and objectives from your minimap without constantly reopening the world map.
- Pick nearby services from a movable HUD menu and show auctioneers, bankers, flight masters,
  mailboxes, vendors and class-matched trainers on both maps.
- Know instantly why a creature matters through live quest progress in its tooltip.
- Watch every quest in your log at once in a movable tracker window, grouped by zone, with live objective progress.
- Keep your chosen quests tracked across interface reloads.
- Recognize relevant quest creatures faster with automatic quest marks.
- Bring your finished quests with you: if you have been questing with pfQuest, import its
  completed-quest history in one click so old quest markers stop coming back. It works even
  after you disable pfQuest -- the import borrows it for a single reload and switches it
  back off.

## Stop searching. Start adventuring.

Azeroth should feel mysterious, not frustrating. UnrealQuest gives you the direction you need while keeping the journey in your hands. Objective areas guide you toward the right part of the world, nearby targets become easier to spot, and useful quest information appears exactly when you need it.

No more circling the same field wondering where a creature spawns. No more forgetting which NPC wanted an item. No more losing your tracked quests after a reload. UnrealQuest keeps the adventure moving so you can spend more time exploring, fighting and finishing the stories you started.

Install UnrealQuest and experience questing built specifically for Unreal Azeroth.

## Screenshots

### Turn your world map into a questing compass

Blue objective areas show you where to search, while `!` and `?` markers reveal where new adventures begin and completed journeys end.

![Quest objectives, quest givers and turn-ins on the world map](screenshots/map_tracking.png)

### Find nearby quest targets at a glance

The minimap keeps nearby objectives visible while you move, helping you choose your next direction without breaking the rhythm of exploration.

![Nearby quest targets and quest givers on the minimap](screenshots/minimap.png)

### Know why every creature matters

Hover a relevant creature to see the connected quest and your live objective progress immediately.

![Quest objective progress shown on a creature tooltip](screenshots/tooltip_quest.png)

### Discover quests before you make the journey

Quest-giver tooltips show the available quests, their levels and requirements directly from the map, helping you decide where to go next.

![Available quests shown in a world-map tooltip](screenshots/map_tooltip.png)

## Designed for Unreal Azeroth

UnrealQuest is not a generic quest addon forced onto an unfamiliar client. Its tracking, maps, minimap, tooltips and compatibility layer are engineered around the behavior and limitations of Unreal Azeroth / Emberveil. The result is a focused questing experience that feels native to this world.

Use `/uq` in game to view the available commands and diagnostics.

The `NPC` HUD button can be dragged anywhere. Click it to select or clear service categories;
the class-trainer row automatically shows only trainers for your character's class.

## Version

Current release: 0.0.2

## License

UnrealQuest is released under the MIT License. Bundled world data originates from VMaNGOS and was packaged by pfQuest under the MIT License; see [LICENSE](LICENSE) and [Database/CREDITS.md](Database/CREDITS.md).
