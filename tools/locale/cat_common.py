# -*- coding: utf-8 -*-
# Shared / UI-surface strings. key -> (en, fr, ru, cn)

STRINGS = {}

STRINGS.update({
# --- common ------------------------------------------------------------------
"COMMON_YES": ("yes", "oui", "да", "是"),
"COMMON_NO": ("no", "non", "нет", "否"),
"COMMON_ON": ("on", "activé", "вкл", "开"),
"COMMON_OFF": ("off", "désactivé", "выкл", "关"),
"COMMON_CLOSE": ("Close", "Fermer", "Закрыть", "关闭"),
"COMMON_UNKNOWN": ("Unknown", "Inconnu", "Неизвестно", "未知"),
"COMMON_NONE": ("none", "aucun", "нет", "无"),
"COMMON_NONE_ANGLED": ("<none>", "<aucun>", "<нет>", "<无>"),
"COMMON_NOTHING": ("nothing", "rien", "ничего", "无"),
"COMMON_NOT_FOUND": ("not found", "introuvable", "не найдено", "未找到"),

# --- quest status shared by tracker, map and minimap -------------------------
"QUEST_STATUS_READY_TO_TURN_IN": (
    "Ready to turn in",
    "Prête à rendre",
    "Готово к сдаче",
    "可以交任务",
),
"QUEST_VENDOR_SELLS": (
    "Sells for your quests:",
    "Vend pour vos quêtes :",
    "Продаёт для ваших заданий:",
    "为你的任务出售：",
),
"QUEST_STATUS_IN_PROGRESS": (
    "In progress",
    "En cours",
    "В процессе",
    "进行中",
),

# --- tooltip label/value pairs -----------------------------------------------
"TOOLTIP_LEVEL": ("Level:", "Niveau :", "Уровень:", "等级："),
"TOOLTIP_ZONE": ("Zone:", "Zone :", "Зона:", "区域："),
"TOOLTIP_TYPE": ("Type:", "Type :", "Тип:", "类型："),
"TOOLTIP_TYPE_UNIT": ("Unit", "Créature", "Существо", "生物"),
"TOOLTIP_TYPE_OBJECT": ("Object", "Objet", "Объект", "物件"),
"TOOLTIP_STATUS": ("Status:", "État :", "Статус:", "状态："),
"TOOLTIP_TRACKED": ("Tracked:", "Suivie :", "Отслеживается:", "已追踪："),
"TOOLTIP_TURNS_IN": ("Turns in:", "Rend :", "Принимает:", "可交任务："),
"TOOLTIP_REQUIRED": ("Required:", "Requis :", "Требуется:", "需求："),

# --- tracker window ----------------------------------------------------------
"TRACKER_HINT_LEFT_CLICK": (
    "Left-Click: open in Quest Log",
    "Clic gauche : ouvrir dans le journal de quêtes",
    "ЛКМ: открыть в журнале заданий",
    "左键：在任务日志中打开",
),
"TRACKER_HINT_SHIFT_CLICK": (
    "Shift-Click: remove from tracker",
    "Maj+clic : retirer du suivi",
    "Shift+ЛКМ: убрать из трекера",
    "Shift+左键：从追踪器中移除",
),
"TRACKER_HINT_CTRL_CLICK": (
    "Ctrl-Click: show on the map",
    "Ctrl+clic : afficher sur la carte",
    "Ctrl+ЛКМ: показать на карте",
    "Ctrl+左键：在地图上显示",
),
"TRACKER_HINT_RIGHT_CLICK": (
    "Right-Click: fold objectives",
    "Clic droit : replier les objectifs",
    "ПКМ: свернуть цели",
    "右键：折叠目标",
),
"TRACKER_WARN_NO_POSITION": (
    "the tracker window could not report its position; it will reopen where it was",
    "la fenêtre de suivi n'a pas pu indiquer sa position ; elle rouvrira au même endroit",
    "окно трекера не смогло сообщить свою позицию; оно откроется там же, где было",
    "追踪器窗口无法报告其位置；它将在原处重新打开",
),
"TRACKER_WARN_NO_WINDOW": (
    "the quest tracker window could not be created; the tracker is unavailable",
    "la fenêtre de suivi de quêtes n'a pas pu être créée ; le suivi est indisponible",
    "окно трекера заданий не удалось создать; трекер недоступен",
    "无法创建任务追踪器窗口；追踪器不可用",
),
"RARE_WARN_DRAG_FAILED": (
    "the alert card refused to move (StartMoving failed)",
    "la carte d'alerte a refusé de bouger (échec de StartMoving)",
    "карточка оповещения отказалась перемещаться (StartMoving не сработал)",
    "提醒卡片拒绝移动（StartMoving 失败）",
),
"TRACKER_WARN_DRAG_FAILED": (
    "the tracker window refused to move (StartMoving failed)",
    "la fenêtre de suivi a refusé de bouger (échec de StartMoving)",
    "окно трекера отказалось перемещаться (StartMoving не сработал)",
    "追踪器窗口拒绝移动（StartMoving 失败）",
),
"TRACKER_WARN_NO_HANDLE": (
    "the tracker window has no drag handle; it cannot be moved",
    "la fenêtre de suivi n'a pas de poignée ; elle ne peut pas être déplacée",
    "у окна трекера нет области перетаскивания; его нельзя переместить",
    "追踪器窗口没有拖动区域；无法移动",
),
"TRACKER_WARN_RESIZE_FAILED": (
    "the tracker's corner grip could not start a resize; its size can still be set "
    "with /uq tracker width and /uq tracker height",
    "la poignée d'angle du suivi n'a pas pu lancer un redimensionnement ; sa taille "
    "reste réglable avec /uq tracker width et /uq tracker height",
    "угловой захват трекера не смог начать изменение размера; размер всё ещё можно "
    "задать через /uq tracker width и /uq tracker height",
    "追踪器的角落调整柄无法开始调整大小；仍可用 /uq tracker width 和 "
    "/uq tracker height 设置尺寸",
),
"TRACKER_WARN_NO_GRIP": (
    "the tracker window has no resize grip; its size can still be set with "
    "/uq tracker width and /uq tracker height",
    "la fenêtre de suivi n'a pas de poignée de redimensionnement ; sa taille reste "
    "réglable avec /uq tracker width et /uq tracker height",
    "у окна трекера нет захвата для изменения размера; размер всё ещё можно задать "
    "через /uq tracker width и /uq tracker height",
    "追踪器窗口没有调整大小的手柄；仍可用 /uq tracker width 和 "
    "/uq tracker height 设置尺寸",
),

# --- quest log buttons -------------------------------------------------------
"QUESTLOG_BUTTON_SHOW": ("Show", "Voir", "Показать", "显示"),
"QUESTLOG_BUTTON_TRACK": ("Track", "Suivre", "Следить", "追踪"),
"QUESTLOG_BUTTON_UNTRACK": ("Untrack", "Ne plus suivre", "Не следить", "取消追踪"),

# --- world map ---------------------------------------------------------------
"MAP_HINT_SHIFT_CLICK_CHOOSE": (
    "Shift-click to choose which quest is already done",
    "Maj+clic pour choisir la quête déjà terminée",
    "Shift+клик, чтобы выбрать, какое задание уже выполнено",
    "Shift+点击以选择哪个任务已完成",
),
"MAP_HINT_SHIFT_CLICK_MARK": (
    "Shift-click to mark as already done",
    "Maj+clic pour marquer comme déjà terminée",
    "Shift+клик, чтобы отметить как уже выполненное",
    "Shift+点击以标记为已完成",
),
"MAP_GIVER_MENU_MARK_ALL": (
    "Mark all as done",
    "Tout marquer comme terminé",
    "Отметить все как выполненные",
    "全部标记为已完成",
),

# --- NPC finder categories ---------------------------------------------------
"NPC_CATEGORY_TRAINER": ("Class Trainer", "Maître de classe", "Учитель класса", "职业训练师"),
"NPC_CATEGORY_AUCTIONEER": ("Auctioneer", "Commissaire-priseur", "Аукционист", "拍卖师"),
"NPC_CATEGORY_BANKER": ("Banker", "Banquier", "Банкир", "银行家"),
"NPC_CATEGORY_BATTLEMASTER": ("Battlemaster", "Maître de guerre", "Военачальник", "战场指挥官"),
"NPC_CATEGORY_FLIGHT": ("Flight Master", "Maître de vol", "Распорядитель полётов", "飞行管理员"),
"NPC_CATEGORY_INNKEEPER": ("Innkeeper", "Aubergiste", "Трактирщик", "旅店老板"),
"NPC_CATEGORY_MAILBOX": ("Mailbox", "Boîte aux lettres", "Почтовый ящик", "邮箱"),
"NPC_CATEGORY_MEETINGSTONE": ("Meeting Stone", "Pierre de rencontre", "Камень встреч", "集合石"),
"NPC_CATEGORY_REPAIR": ("Repair", "Réparation", "Ремонт", "修理"),
"NPC_CATEGORY_SPIRITHEALER": ("Spirit Healer", "Guérisseur des esprits", "Дух-целитель", "灵魂医者"),
"NPC_CATEGORY_STABLEMASTER": ("Stable Master", "Maître des écuries", "Смотритель стойл", "兽栏管理员"),
"NPC_CATEGORY_VENDOR": ("Vendor", "Marchand", "Торговец", "商人"),
"NPC_CATEGORY_INSTANCES": ("Dungeon entrances", "Entrees de donjons", "Входы в подземелья", "地下城入口"),
"NPC_CATEGORY_CHESTS": ("Chests & Treasures", "Coffres et trésors", "Сундуки и сокровища", "宝箱与财宝"),
"NPC_CATEGORY_HERBS": ("Herbs & Flowers", "Herbes et fleurs", "Травы и цветы", "草药与花卉"),
"NPC_CATEGORY_MINES": ("Mines & Ores", "Mines et minerais", "Жилы и руда", "矿脉与矿石"),
"NPC_CATEGORY_FISH": ("Fishing Pools", "Bancs de poissons", "Рыбные места", "钓鱼点"),
"NPC_CATEGORY_RARES": ("Rare/Elite/Boss", "Rare/Elite/Boss", "Редкие/элитные/боссы", "稀有/精英/首领"),
"NPC_DETAIL_SKILL": ("(skill %s)", "(compétence %s)", "(навык %s)", "（技能 %s）"),
"NPC_DETAIL_LEVEL": ("(level %s)", "(niveau %s)", "(уровень %s)", "（等级 %s）"),

# --- raid marks --------------------------------------------------------------
"MARK_STAR": ("star", "étoile", "звезда", "星星"),
"MARK_CIRCLE": ("circle", "cercle", "круг", "圆圈"),
"MARK_DIAMOND": ("diamond", "losange", "ромб", "菱形"),
"MARK_TRIANGLE": ("triangle", "triangle", "треугольник", "三角"),
"MARK_MOON": ("moon", "lune", "полумесяц", "月亮"),
"MARK_SQUARE": ("square", "carré", "квадрат", "方块"),
"MARK_CROSS": ("cross", "croix", "крест", "十字"),
"MARK_SKULL": ("skull", "crâne", "череп", "骷髅"),
"MARK_UNNAMED": ("mark %s", "marque %s", "метка %s", "标记 %s"),
"MARKS_WARN_REFUSED": (
    "raid marks are not being accepted -- see /uq marks",
    "les marques de raid ne sont pas acceptées -- voir /uq marks",
    "метки рейда не принимаются -- см. /uq marks",
    "团队标记未被接受 -- 见 /uq marks",
),

# --- main quest / reveal on map ----------------------------------------------
"MAINQUEST_NOW_FOLLOWING": ("following %s", "suivi de %s", "следуем за %s", "正在跟随 %s"),
"MAINQUEST_NO_LONGER_FOLLOWING": (
    "no longer following %s",
    "%s n'est plus suivie",
    "больше не следуем за %s",
    "不再跟随 %s",
),
"REVEAL_NO_QUEST_ID": (
    "'%s' has no resolved quest id, so it cannot be shown on the map",
    "'%s' n'a pas d'identifiant de quête résolu, elle ne peut pas être montrée sur la carte",
    "у «%s» нет определённого идентификатора задания, поэтому его нельзя показать на карте",
    "“%s”没有解析出的任务 ID，因此无法在地图上显示",
),
"REVEAL_TURN_IN_ELSEWHERE": (
    "'%s': hand it in in %s -- not the zone currently shown on the map, so nothing "
    "could be flashed there",
    "'%s' : à rendre en %s -- ce n'est pas la zone affichée sur la carte, rien n'a "
    "donc pu y être mis en évidence",
    "«%s»: сдать в %s -- это не та зона, что открыта на карте, поэтому подсветить "
    "там нечего",
    "“%s”：请在 %s 交任务 -- 这不是当前地图显示的区域，因此无法在此高亮",
),
"REVEAL_OBJECTIVES_ELSEWHERE": (
    "'%s': its objectives are in %s -- not the zone currently shown on the map, so "
    "nothing could be flashed there",
    "'%s' : ses objectifs sont en %s -- ce n'est pas la zone affichée sur la carte, "
    "rien n'a donc pu y être mis en évidence",
    "«%s»: цели находятся в %s -- это не та зона, что открыта на карте, поэтому "
    "подсветить там нечего",
    "“%s”：其目标位于 %s -- 这不是当前地图显示的区域，因此无法在此高亮",
),
"REVEAL_NOTHING_KNOWN": (
    "no map marker for '%s' is currently rendered, and the bundled data records no "
    "location for it either (hidden from the map, or simply not one this addon's data covers)",
    "aucun marqueur n'est actuellement affiché pour '%s', et les données fournies "
    "n'indiquent aucun emplacement pour elle (masquée de la carte, ou simplement "
    "absente des données de cet addon)",
    "для «%s» сейчас не отрисован ни один маркер, и во встроенных данных для него "
    "тоже нет местоположения (скрыто с карты либо просто не покрыто данными аддона)",
    "当前没有为“%s”绘制任何地图标记，随附数据中也没有它的位置（已从地图隐藏，"
    "或本插件的数据未收录）",
),

# --- HUD waypoint ------------------------------------------------------------
"WAYPOINT_DISTANCE_YARDS": ("%s yd", "%s m", "%s м", "%s 码"),
"WAYPOINT_DISTANCE_KILOYARDS": ("%s k", "%s k", "%s тыс.", "%s 千"),

# --- world scan failures -----------------------------------------------------
"WORLDSCAN_NO_WORLDFRAME": (
    "WorldFrame is not reachable as an object",
    "WorldFrame n'est pas accessible en tant qu'objet",
    "WorldFrame недоступен как объект",
    "无法将 WorldFrame 作为对象访问",
),
"WORLDSCAN_NO_CHILD_COUNT": (
    "WorldFrame did not answer GetNumChildren",
    "WorldFrame n'a pas répondu à GetNumChildren",
    "WorldFrame не ответил на GetNumChildren",
    "WorldFrame 未响应 GetNumChildren",
),
"WORLDSCAN_NO_CHILDREN": (
    "WorldFrame did not answer GetChildren",
    "WorldFrame n'a pas répondu à GetChildren",
    "WorldFrame не ответил на GetChildren",
    "WorldFrame 未响应 GetChildren",
),

# --- core infrastructure warnings --------------------------------------------
"CONFIG_SCHEMA_RESET": (
    "saved settings were written by schema %s; resetting to schema %s",
    "les réglages enregistrés ont été écrits par le schéma %s ; réinitialisation "
    "au schéma %s",
    "сохранённые настройки записаны схемой %s; сброс к схеме %s",
    "已保存的设置由架构 %s 写入；正在重置为架构 %s",
),
"CONFIG_UNSUPPORTED_VALUE": (
    "refused to persist an unsupported value for %s",
    "refus d'enregistrer une valeur non prise en charge pour %s",
    "отказано в сохранении неподдерживаемого значения для %s",
    "拒绝为 %s 保存不受支持的值",
),
"CONFIG_SECTION_FULL": (
    "section %s is full; entry not stored",
    "la section %s est pleine ; entrée non enregistrée",
    "раздел %s заполнен; запись не сохранена",
    "分区 %s 已满；条目未保存",
),
"DRIVER_JOB_DISABLED": (
    "job %s disabled after repeated failures",
    "tâche %s désactivée après des échecs répétés",
    "задача %s отключена после повторных сбоев",
    "任务 %s 因反复失败而被停用",
),
"DRIVER_NO_FRAME": (
    "could not create the shared driver frame; periodic work is disabled",
    "impossible de créer le cadre de pilotage partagé ; le travail périodique est désactivé",
    "не удалось создать общий кадр драйвера; периодические задачи отключены",
    "无法创建共享驱动框体；周期性任务已停用",
),
"EVENTS_NO_FRAME": (
    "could not create the event frame; UnrealQuest will rely on polling alone",
    "impossible de créer le cadre d'événements ; UnrealQuest s'appuiera uniquement "
    "sur le sondage",
    "не удалось создать кадр событий; UnrealQuest будет полагаться только на опрос",
    "无法创建事件框体；UnrealQuest 将仅依赖轮询",
),

# --- bootstrap ---------------------------------------------------------------
"BOOT_LOADED": (
    "v%s loaded. /uq for status.",
    "v%s chargé. /uq pour l'état.",
    "v%s загружен. /uq для статуса.",
    "v%s 已加载。输入 /uq 查看状态。",
),
"BOOT_MODULE_INIT_FAILED": (
    "%s failed to initialize: %s",
    "Échec de l'initialisation de %s : %s",
    "Не удалось инициализировать %s: %s",
    "%s 初始化失败：%s",
),
"BOOT_MODULE_ENABLE_FAILED": (
    "%s failed to enable: %s",
    "Échec de l'activation de %s : %s",
    "Не удалось включить %s: %s",
    "%s 启用失败：%s",
),
})

# --- settings page -----------------------------------------------------------
STRINGS.update({
"SETTINGS_TRACKER_OPACITY": (
    "Background opacity", "Opacité du fond", "Непрозрачность фона", "背景不透明度"),
"SETTINGS_TRACKER_CURRENT_ZONE": (
    "Only show quests from the current zone",
    "N'afficher que les quêtes de la zone actuelle",
    "Показывать только задания текущей зоны",
    "仅显示当前区域的任务",
),
"SETTINGS_HEADING_WORLD_MAP": ("World map", "Carte du monde", "Карта мира", "世界地图"),
"SETTINGS_MAP_OBJECTIVE_STYLE": (
    "Quest objectives are shown as:",
    "Les objectifs de quête sont affichés en :",
    "Цели заданий показываются как:",
    "任务目标显示为：",
),
"SETTINGS_MAP_STYLE_DOTS": ("Dots", "Points", "Точки", "圆点"),
"SETTINGS_MAP_STYLE_DOTS_NOTE": (
    "One dot per target position, in the same style as the minimap pins.",
    "Un point par position de cible, dans le même style que les repères de la mini-carte.",
    "По одной точке на каждую позицию цели, в том же стиле, что и метки миникарты.",
    "每个目标位置一个圆点，样式与小地图标记相同。",
),
"SETTINGS_MAP_STYLE_AREAS": ("Areas", "Zones", "Области", "区域"),
"SETTINGS_MAP_STYLE_AREAS_NOTE": (
    "A shaded blue area covering where the targets are found.",
    "Une zone bleue ombrée couvrant l'endroit où se trouvent les cibles.",
    "Синяя закрашенная область, охватывающая места, где встречаются цели.",
    "以蓝色阴影区域覆盖目标出现的范围。",
),
"SETTINGS_MAP_DOT_SIZE": (
    "World map dot size", "Taille des points sur la carte",
    "Размер точек на карте мира", "世界地图圆点大小"),
"SETTINGS_MINIMAP_DOT_SIZE": (
    "Minimap dot size", "Taille des points sur la mini-carte",
    "Размер точек на миникарте", "小地图圆点大小"),
"SETTINGS_MAP_CLUSTER": (
    "Describe overlapping map markers together",
    "Décrire ensemble les marqueurs superposés",
    "Описывать перекрывающиеся маркеры вместе",
    "将重叠的地图标记一并说明",
),
"SETTINGS_MAP_CLUSTER_NOTE": (
    "Markers whose icons touch cannot be hovered apart; this lists them all.",
    "Les marqueurs dont les icônes se touchent ne peuvent pas être survolés "
    "séparément ; ceci les liste tous.",
    "Маркеры с соприкасающимися значками нельзя навести по отдельности; "
    "это перечисляет их все.",
    "图标相接的标记无法分别悬停；此选项会将它们全部列出。",
),
"SETTINGS_LOW_LEVEL_QUESTS": (
    "Show low-level quests",
    "Afficher les quetes de bas niveau",
    "Показывать задания низкого уровня",
    "显示低等级任务",
),
"SETTINGS_TRANSLATE_QUEST_TITLES": (
    "Translate quest text",
    "Traduire le texte des quetes",
    "Переводить текст заданий",
    "翻译任务文本",
),
"SETTINGS_TRACKER_HIDE_UNSTARTED": (
    "Hide quests until progress starts",
    "Masquer les quetes sans progression",
    "Скрывать задания без прогресса",
    "隐藏尚无进度的任务",
),
"SETTINGS_MINIMAP_CLAMP": (
    "Clamp off-view minimap markers to the edge",
    "Coller au bord les marqueurs hors champ de la mini-carte",
    "Прижимать к краю миникарты маркеры вне обзора",
    "将视野外的小地图标记固定在边缘",
),
"SETTINGS_MINIMAP_CLAMP_NOTE": (
    "Off hides distant \"!\" and \"?\" markers instead of pinning them to the border.",
    "Désactivé, les marqueurs \"!\" et \"?\" lointains sont masqués au lieu d'être "
    "collés au bord.",
    "При выключении далёкие маркеры «!» и «?» скрываются, а не прижимаются к краю.",
    "关闭时将隐藏远处的“!”和“?”标记，而不是把它们固定在边框上。",
),
"SETTINGS_HEADING_QUEST_HISTORY": (
    "Quest history", "Historique des quêtes", "История заданий", "任务历史"),
"SETTINGS_PFQUEST_CHECKING": (
    "Checking for pfQuest data...",
    "Recherche des données pfQuest...",
    "Проверка данных pfQuest...",
    "正在检查 pfQuest 数据……",
),
"SETTINGS_MINIMAP_TOOLTIP": (
    "Click to open the options.",
    "Cliquez pour ouvrir les options.",
    "Нажмите, чтобы открыть настройки.",
    "点击打开选项。",
),
"SETTINGS_IN_UNREALUI": (
    "the UnrealQuest options are in the unrealUI settings window (/uui)",
    "les options d'UnrealQuest se trouvent dans la fenêtre de réglages d'unrealUI (/uui)",
    "настройки UnrealQuest находятся в окне настроек unrealUI (/uui)",
    "UnrealQuest 的选项位于 unrealUI 的设置窗口中（/uui）",
),
"SETTINGS_LANGUAGE_CHANGED": (
    "language set to %s",
    "langue réglée sur %s",
    "язык установлен на %s",
    "语言已设为 %s",
),
"SETTINGS_LANGUAGE_RELOAD": (
    "  type /reload to redraw the interface in it",
    "  tapez /reload pour redessiner l'interface dans cette langue",
    "  введите /reload, чтобы перерисовать интерфейс на этом языке",
    "  输入 /reload 以用该语言重绘界面",
),
"SETTINGS_WARN_PAGE_TOO_TALL": (
    "the options page is %spx tall but the window shows %spx; the last options are cut off",
    "la page d'options fait %s px de haut mais la fenêtre en affiche %s ; les dernières "
    "options sont coupées",
    "страница настроек высотой %s px, а окно показывает %s px; последние параметры обрезаны",
    "选项页面高 %s 像素，但窗口仅显示 %s 像素；最后几个选项被截断",
),
"SETTINGS_WARN_UNREALUI_REFUSED": (
    "unrealUI refused the UnrealQuest options page; using UnrealQuest's own window",
    "unrealUI a refusé la page d'options d'UnrealQuest ; utilisation de la fenêtre "
    "propre à UnrealQuest",
    "unrealUI отклонил страницу настроек UnrealQuest; используется собственное окно UnrealQuest",
    "unrealUI 拒绝了 UnrealQuest 的选项页面；改用 UnrealQuest 自己的窗口",
),
"SETTINGS_WARN_NO_WINDOW": (
    "the settings window could not be created; every option is still on /uq",
    "la fenêtre de réglages n'a pas pu être créée ; toutes les options restent sur /uq",
    "окно настроек не удалось создать; все параметры по-прежнему доступны через /uq",
    "无法创建设置窗口；所有选项仍可通过 /uq 使用",
),
"SETTINGS_WARN_DRAG_FAILED": (
    "the settings window refused to move (StartMoving failed)",
    "la fenêtre de réglages a refusé de bouger (échec de StartMoving)",
    "окно настроек отказалось перемещаться (StartMoving не сработал)",
    "设置窗口拒绝移动（StartMoving 失败）",
),
"SETTINGS_WARN_NO_HANDLE": (
    "the settings window has no drag handle; it cannot be moved",
    "la fenêtre de réglages n'a pas de poignée ; elle ne peut pas être déplacée",
    "у окна настроек нет области перетаскивания; его нельзя переместить",
    "设置窗口没有拖动区域；无法移动",
),
"SETTINGS_WARN_NO_POSITION": (
    "the settings window could not report its position; it will reopen where it was",
    "la fenêtre de réglages n'a pas pu indiquer sa position ; elle rouvrira au même endroit",
    "окно настроек не смогло сообщить свою позицию; оно откроется там же, где было",
    "设置窗口无法报告其位置；它将在原处重新打开",
),
})

# --- pfQuest import ----------------------------------------------------------
STRINGS.update({
"PFQUEST_BUTTON_IMPORT": (
    "Import from pfQuest", "Importer depuis pfQuest", "Импорт из pfQuest", "从 pfQuest 导入"),
"PFQUEST_BUTTON_WAITING": (
    "Waiting for /reload", "En attente de /reload", "Ожидание /reload", "等待 /reload"),
"PFQUEST_BUTTON_NOT_INSTALLED": (
    "pfQuest not installed", "pfQuest non installé", "pfQuest не установлен", "未安装 pfQuest"),
"PFQUEST_BUTTON_NO_HISTORY": (
    "pfQuest has no history", "pfQuest n'a pas d'historique",
    "У pfQuest нет истории", "pfQuest 没有历史记录"),
"PFQUEST_BUTTON_ENABLE_AND_IMPORT": (
    "Enable pfQuest and import", "Activer pfQuest et importer",
    "Включить pfQuest и импортировать", "启用 pfQuest 并导入"),

"PFQUEST_SHORT_EMPTY_HISTORY": (
    "pfQuest is loaded, but its history for this character is empty.",
    "pfQuest est chargé, mais son historique pour ce personnage est vide.",
    "pfQuest загружен, но его история для этого персонажа пуста.",
    "pfQuest 已加载，但该角色的历史记录为空。",
),
"PFQUEST_SHORT_NOTHING_NEW": (
    "pfQuest's history holds nothing this addon has not already recorded.",
    "L'historique de pfQuest ne contient rien que cet addon n'ait déjà enregistré.",
    "В истории pfQuest нет ничего, чего аддон ещё не записал.",
    "pfQuest 的历史记录中没有本插件尚未记录的内容。",
),
"PFQUEST_SHORT_PENDING": (
    "pfQuest is on for one reload -- type /reload to run the import.",
    "pfQuest est activé pour un rechargement -- tapez /reload pour lancer l'import.",
    "pfQuest включён на одну перезагрузку -- введите /reload, чтобы выполнить импорт.",
    "pfQuest 已为一次重载启用 -- 输入 /reload 以运行导入。",
),
"PFQUEST_SHORT_DISABLED": (
    "pfQuest is installed but disabled -- the button borrows it for one reload.",
    "pfQuest est installé mais désactivé -- le bouton l'emprunte pour un rechargement.",
    "pfQuest установлен, но отключён -- кнопка позаимствует его на одну перезагрузку.",
    "pfQuest 已安装但被禁用 -- 按钮会为一次重载临时借用它。",
),
"PFQUEST_SHORT_MISSING": (
    "pfQuest is not installed, so there is no saved history to import.",
    "pfQuest n'est pas installé, il n'y a donc aucun historique à importer.",
    "pfQuest не установлен, поэтому импортировать нечего.",
    "未安装 pfQuest，因此没有可导入的历史记录。",
),
"PFQUEST_SHORT_EMPTY": (
    "pfQuest is loaded but has recorded no completed quests here.",
    "pfQuest est chargé mais n'a enregistré aucune quête terminée ici.",
    "pfQuest загружен, но не записал здесь ни одного выполненного задания.",
    "pfQuest 已加载，但此处未记录任何已完成的任务。",
),
"PFQUEST_SHORT_NO_HISTORY_YET": (
    "pfQuest is enabled but has written no history for this character yet.",
    "pfQuest est activé mais n'a pas encore écrit d'historique pour ce personnage.",
    "pfQuest включён, но ещё не записал историю для этого персонажа.",
    "pfQuest 已启用，但尚未为该角色写入历史记录。",
),

"PFQUEST_LONG_PENDING": (
    "pfQuest has been switched on for one reload. Type /reload and the import runs "
    "by itself, then switches it off again.",
    "pfQuest a été activé pour un rechargement. Tapez /reload : l'import se lance "
    "tout seul, puis le désactive à nouveau.",
    "pfQuest включён на одну перезагрузку. Введите /reload -- импорт выполнится сам, "
    "после чего pfQuest снова выключится.",
    "pfQuest 已为一次重载启用。输入 /reload，导入会自动运行，随后再次将其关闭。",
),
"PFQUEST_LONG_DISABLED": (
    "pfQuest is installed but disabled, so its saved history is not in memory. The "
    "button switches it on for one reload, imports, and switches it back off.",
    "pfQuest est installé mais désactivé, son historique n'est donc pas en mémoire. "
    "Le bouton l'active pour un rechargement, importe, puis le désactive.",
    "pfQuest установлен, но отключён, поэтому его история не в памяти. Кнопка включит "
    "его на одну перезагрузку, выполнит импорт и снова выключит.",
    "pfQuest 已安装但被禁用，因此其保存的历史不在内存中。按钮会为一次重载启用它，"
    "完成导入后再将其关闭。",
),
"PFQUEST_LONG_MISSING": (
    "pfQuest is not installed, so there is no saved history to import from.",
    "pfQuest n'est pas installé, il n'y a donc aucun historique à importer.",
    "pfQuest не установлен, поэтому импортировать историю неоткуда.",
    "未安装 pfQuest，因此没有可供导入的历史记录。",
),
"PFQUEST_LONG_EMPTY": (
    "pfQuest is loaded but has recorded no completed quests for this character, so "
    "there is nothing to import.",
    "pfQuest est chargé mais n'a enregistré aucune quête terminée pour ce personnage, "
    "il n'y a donc rien à importer.",
    "pfQuest загружен, но не записал для этого персонажа ни одного выполненного "
    "задания, поэтому импортировать нечего.",
    "pfQuest 已加载，但未记录该角色任何已完成的任务，因此没有可导入的内容。",
),
"PFQUEST_LONG_NOT_RUN_YET": (
    "pfQuest is enabled but its files have not run yet -- type /reload.",
    "pfQuest est activé mais ses fichiers n'ont pas encore été exécutés -- tapez /reload.",
    "pfQuest включён, но его файлы ещё не выполнены -- введите /reload.",
    "pfQuest 已启用，但其文件尚未运行 -- 请输入 /reload。",
),
"PFQUEST_LONG_COUNTS": (
    "%s completed in pfQuest's history: %s to import, %s already here.",
    "%s terminées dans l'historique de pfQuest : %s à importer, %s déjà présentes.",
    "%s выполнено в истории pfQuest: %s к импорту, %s уже здесь.",
    "pfQuest 历史中有 %s 个已完成：%s 个待导入，%s 个已存在。",
),
"PFQUEST_LONG_WAITING": (
    "%s waiting on the title index.",
    "%s en attente de l'index des titres.",
    "%s ожидают индекс названий.",
    "%s 个正在等待标题索引。",
),
"PFQUEST_LONG_SKIPPED": (
    "%s skipped (not in this client's quest data, or an ambiguous title).",
    "%s ignorées (absentes des données de quête de ce client, ou titre ambigu).",
    "%s пропущено (нет в данных заданий этого клиента либо неоднозначное название).",
    "%s 个已跳过（不在此客户端的任务数据中，或标题不明确）。",
),
"PFQUEST_LONG_PREVIOUS": (
    "%s imported previously.",
    "%s importées précédemment.",
    "%s импортировано ранее.",
    "%s 个先前已导入。",
),

"PFQUEST_PRESS_MISSING": (
    "pfQuest is not installed, so there is no saved history to import",
    "pfQuest n'est pas installé, il n'y a donc aucun historique à importer",
    "pfQuest не установлен, поэтому импортировать нечего",
    "未安装 pfQuest，因此没有可导入的历史记录",
),
"PFQUEST_PRESS_EMPTY": (
    "pfQuest is loaded but has recorded no completed quests for this character, so "
    "there is nothing to import",
    "pfQuest est chargé mais n'a enregistré aucune quête terminée pour ce personnage, "
    "il n'y a donc rien à importer",
    "pfQuest загружен, но не записал для этого персонажа ни одного выполненного "
    "задания, поэтому импортировать нечего",
    "pfQuest 已加载，但未记录该角色任何已完成的任务，因此没有可导入的内容",
),
"PFQUEST_PRESS_ALREADY_PENDING": (
    "pfQuest is already switched on for the import -- type /reload to run it",
    "pfQuest est déjà activé pour l'import -- tapez /reload pour le lancer",
    "pfQuest уже включён для импорта -- введите /reload, чтобы выполнить его",
    "pfQuest 已为导入启用 -- 输入 /reload 以运行",
),
"PFQUEST_NOTHING_NEW": (
    "nothing new to import: %s",
    "rien de nouveau à importer : %s",
    "нет ничего нового для импорта: %s",
    "没有新内容可导入：%s",
),
"PFQUEST_ENABLE_REFUSED": (
    "the client would not change pfQuest's enabled state; enable pfQuest in the addon "
    "list yourself and press this again",
    "le client a refusé de changer l'état d'activation de pfQuest ; activez pfQuest "
    "vous-même dans la liste des addons puis réessayez",
    "клиент не изменил состояние pfQuest; включите pfQuest в списке аддонов вручную "
    "и нажмите ещё раз",
    "客户端未能更改 pfQuest 的启用状态；请自行在插件列表中启用 pfQuest 后再试一次",
),
"PFQUEST_ENABLED_FOR_RELOAD": (
    "pfQuest has been switched on for one reload",
    "pfQuest a été activé pour un rechargement",
    "pfQuest включён на одну перезагрузку",
    "pfQuest 已为一次重载启用",
),
"PFQUEST_ENABLED_FOR_RELOAD_HINT": (
    "type /reload -- the import runs by itself, then switches pfQuest back off",
    "tapez /reload -- l'import se lance tout seul, puis désactive à nouveau pfQuest",
    "введите /reload -- импорт выполнится сам, затем pfQuest снова выключится",
    "输入 /reload -- 导入会自动运行，随后再次关闭 pfQuest",
),
"PFQUEST_RESUME_NOTHING_NEW": (
    "pfQuest's history had nothing new to import",
    "l'historique de pfQuest n'avait rien de nouveau à importer",
    "в истории pfQuest не нашлось ничего нового для импорта",
    "pfQuest 的历史记录中没有新内容可导入",
),
"PFQUEST_RESTORED_OFF": (
    "pfQuest has been switched back off, as it was before",
    "pfQuest a été désactivé, comme avant",
    "pfQuest снова выключен, как и было раньше",
    "pfQuest 已恢复为关闭状态",
),
"PFQUEST_RESUME_TIMED_OUT": (
    "pfQuest was switched on for the import but its history never appeared; nothing "
    "was imported and pfQuest has been put back as it was",
    "pfQuest a été activé pour l'import mais son historique n'est jamais apparu ; "
    "rien n'a été importé et pfQuest a été remis comme avant",
    "pfQuest был включён для импорта, но его история так и не появилась; ничего не "
    "импортировано, pfQuest возвращён в прежнее состояние",
    "已为导入启用 pfQuest，但其历史记录始终未出现；未导入任何内容，"
    "pfQuest 已恢复原状",
),

# --- rare / elite proximity alert --------------------------------------------
# The four creature ranks the bundled world data carries in units[id].rnk.
"RARE_RANK_ELITE": (u"Elite", u"Élite", u"Элитный", u"精英"),
"RARE_RANK_RARE_ELITE": (
    u"Rare Elite",
    u"Élite rare",
    u"Редкий элитный",
    u"稀有精英",
),
"RARE_RANK_BOSS": (
    u"Boss",
    u"Boss",
    u"Босс",
    u"首领",
),
"RARE_RANK_RARE": (
    u"Rare",
    u"Rare",
    u"Редкий",
    u"稀有",
),

# Compass directions on the north-up MAP, not headings relative to the player:
# this client has no readable player facing, so "ahead of you" cannot be said.
"RARE_DIR_N": (u"north", u"au nord", u"к северу", u"北方"),
"RARE_DIR_NE": (u"north-east", u"au nord-est", u"к северо-востоку", u"东北方"),
"RARE_DIR_E": (u"east", u"à l'est", u"к востоку", u"东方"),
"RARE_DIR_SE": (u"south-east", u"au sud-est", u"к юго-востоку", u"东南方"),
"RARE_DIR_S": (u"south", u"au sud", u"к югу", u"南方"),
"RARE_DIR_SW": (u"south-west", u"au sud-ouest", u"к юго-западу", u"西南方"),
"RARE_DIR_W": (u"west", u"à l'ouest", u"к западу", u"西方"),
"RARE_DIR_NW": (u"north-west", u"au nord-ouest", u"к северо-западу", u"西北方"),

# The line the card opens on. One per rank, not one pattern with the rank
# poured into it: French alone needs "un rare" against "une elite rare".
"RARE_NEARBY_RARE": (
    u"A rare creature is nearby",
    u"Une créature rare est à proximité",
    u"Рядом редкое существо",
    u"附近有稀有怪",
),
"RARE_NEARBY_RARE_ELITE": (
    u"A rare elite is nearby",
    u"Une élite rare est à proximité",
    u"Рядом редкий элитный",
    u"附近有稀有精英",
),
"RARE_NEARBY_BOSS": (
    u"A boss is nearby",
    u"Un boss est à proximité",
    u"Рядом босс",
    u"附近有首领",
),
"RARE_NEARBY_ELITE": (
    u"An elite is nearby",
    u"Une élite est à proximité",
    u"Рядом элитный",
    u"附近有精英",
),
"RARE_ALERT_SUBTITLE_LEVEL": (
    u"%s — level %s",
    u"%s — niveau %s",
    u"%s — уровень %s",
    u"%s — %s 级",
),
"RARE_ALERT_BODY": (
    u"%s yards %s",
    u"%s mètres %s",
    u"%s м — %s",
    u"%s 码，%s",
),
"RARE_ALERT_CHAT": (
    u"%s (%s) is within %s yards of a recorded spawn",
    u"%s (%s) est à %s mètres d'une apparition connue",
    u"%s (%s) — в %s м от известной точки появления",
    u"%s（%s）距已知刷新点 %s 码",
),

# --- settings page: the rare alert rows --------------------------------------
"SETTINGS_RARE_ALERT": (
    u"Elite mobs alert",
    u"Alerte monstres elites",
    u"Оповещение об элитных",
    u"精英怪提醒",
),
"SETTINGS_RARE_ALERT_NOTE": (
    u"Alert within %s yd of elite mobs.",
    u"Alerte a %s m des elites.",
    u"Оповещение в %s м от элитных.",
    u"距精英怪 %s 码时提醒。",
),
})
