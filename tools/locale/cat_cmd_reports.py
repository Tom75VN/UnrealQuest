# -*- coding: utf-8 -*-
# /uq diagnostic and action output. key -> (en, fr, ru, cn)

STRINGS = {

# --- status ------------------------------------------------------------------
"CMD_STATUS_TITLE": (
    "v%s capability report", "v%s rapport de capacités",
    "v%s отчёт о возможностях", "v%s 功能报告"),
"CMD_STATUS_SNAPSHOT_COMPLETE": ("complete", "complet", "полный", "完整"),
"CMD_STATUS_OBJECTIVE_PATH": (
    "objective readout path: %s", "voie de lecture des objectifs : %s",
    "путь чтения целей: %s", "目标读取路径：%s"),

# --- quests ------------------------------------------------------------------
"CMD_QUESTS_NONE": (
    "no quests in the log", "aucune quête dans le journal",
    "в журнале нет заданий", "日志中没有任务"),
"CMD_QUESTS_FLAG_COMPLETE": ("complete", "terminée", "выполнено", "已完成"),
"CMD_QUESTS_FLAG_FAILED": ("failed", "échouée", "провалено", "已失败"),
"CMD_QUESTS_FLAG_TRACKED": ("tracked", "suivie", "отслеж.", "已追踪"),

# --- events ------------------------------------------------------------------
"CMD_EVENTS_TITLE": (
    "event registration on this client:",
    "enregistrement des événements sur ce client :",
    "регистрация событий на этом клиенте:",
    "此客户端的事件注册情况：",
),
"CMD_EVENTS_ACCEPTED": ("accepted", "accepté", "принято", "已接受"),
"CMD_EVENTS_REJECTED": ("rejected", "refusé", "отклонено", "已拒绝"),
"CMD_EVENTS_FIRED": (
    "fired %sx this session", "déclenché %sx cette session",
    "сработало %s раз(а) за сессию", "本次会话触发 %s 次"),
"CMD_EVENTS_FOOTNOTE": (
    "counts persist across sessions; report them to close the quest-event gap",
    "les compteurs persistent entre les sessions ; rapportez-les pour combler le "
    "manque d'événements de quête",
    "счётчики сохраняются между сессиями; сообщите их, чтобы закрыть пробел в "
    "событиях заданий",
    "计数会跨会话保留；请上报以补全任务事件的空白",
),

# --- map ---------------------------------------------------------------------
"CMD_MAP_STYLE_SET_DOTS": (
    "world-map quest objectives drawn as dots",
    "objectifs de quête dessinés en points sur la carte",
    "цели заданий на карте мира рисуются точками",
    "世界地图任务目标以圆点绘制",
),
"CMD_MAP_STYLE_SET_AREAS": (
    "world-map quest objectives drawn as areas",
    "objectifs de quête dessinés en zones sur la carte",
    "цели заданий на карте мира рисуются областями",
    "世界地图任务目标以区域绘制",
),
"CMD_MAP_VENDORS_SET_ON": (
    "quest vendor points are shown",
    "les points marchands des quêtes sont affichés",
    "точки торговцев заданий показаны",
    "已显示任务商人点",
),
"CMD_MAP_VENDORS_SET_OFF": (
    "quest vendor points are hidden",
    "les points marchands des quêtes sont masqués",
    "точки торговцев заданий скрыты",
    "已隐藏任务商人点",
),
"CMD_MAP_VENDORS_USAGE": (
    "usage: /uq map vendors on|off",
    "usage : /uq map vendors on|off",
    "использование: /uq map vendors on|off",
    "用法：/uq map vendors on|off",
),
"CMD_MAP_TITLE": (
    "map observation and current-zone pin status:",
    "observation de la carte et état des repères de la zone actuelle :",
    "наблюдение карты и состояние меток текущей зоны:",
    "地图观测与当前区域标记状态：",
),
"CMD_MAP_MAPFILE": (
    "GetMapInfo file:      %s", "fichier GetMapInfo :  %s",
    "файл GetMapInfo:     %s", "GetMapInfo 文件：    %s"),
"CMD_MAP_TILE_SIZE": (
    "tile height/width:    %s", "hauteur/largeur tuile : %s",
    "высота/ширина тайла: %s", "图块高/宽：          %s"),
"CMD_MAP_CONTINENT_ZONE": (
    "continent / zone idx: %s", "continent / index zone : %s",
    "континент / индекс зоны: %s", "大陆 / 区域索引：    %s"),
"CMD_MAP_ZONE_TEXT": (
    "GetZoneText:          %s", "GetZoneText :        %s",
    "GetZoneText:         %s", "GetZoneText：        %s"),
"CMD_MAP_SUBZONE_TEXT": (
    "GetSubZoneText:       %s", "GetSubZoneText :     %s",
    "GetSubZoneText:      %s", "GetSubZoneText：     %s"),
"CMD_MAP_PLAYER_POSITION": (
    "player map position:  %s", "position du joueur : %s",
    "позиция игрока:      %s", "玩家地图位置：       %s"),
"CMD_MAP_AREA_FROM_MAPFILE": (
    "area id from map file: %s (%s)", "id de zone via fichier de carte : %s (%s)",
    "id зоны из файла карты: %s (%s)", "来自地图文件的区域 ID：%s（%s）"),
"CMD_MAP_AREA_FROM_ZONE_TEXT": (
    "area id from zone text: %s (%s)", "id de zone via texte de zone : %s (%s)",
    "id зоны из текста зоны: %s (%s)", "来自区域文本的区域 ID：%s（%s）"),
"CMD_MAP_AREA_FROM_REAL_ZONE_TEXT": (
    "area id from real zone text: %s (%s)",
    "id de zone via texte de zone réel : %s (%s)",
    "id зоны из реального текста зоны: %s (%s)",
    "来自真实区域文本的区域 ID：%s（%s）"),
"CMD_MAP_ZONE_NAME": (
    "map zone name: %s", "nom de zone de la carte : %s",
    "название зоны карты: %s", "地图区域名称：%s"),
"CMD_MAP_AREA_FROM_MAP_ZONE": (
    "area id from map zone: %s (%s)", "id de zone via zone de carte : %s (%s)",
    "id зоны из зоны карты: %s (%s)", "来自地图区域的区域 ID：%s（%s）"),
"CMD_MAP_AREA_USED": (
    "area id used: %s (%s)", "id de zone utilisé : %s (%s)",
    "используемый id зоны: %s (%s)", "使用的区域 ID：%s（%s）"),
"CMD_MAP_OVERLAY_DISABLED": (
    "map overlay:         disabled", "surcouche de carte : désactivée",
    "слой карты:          отключён", "地图覆盖层：         已停用"),
"CMD_MAP_QUEST_MARKERS": (
    "quest markers:       %s visible / %s pooled",
    "marqueurs de quête : %s visibles / %s en réserve",
    "маркеры заданий:     %s видимых / %s в пуле",
    "任务标记：           %s 可见 / %s 已缓存"),
"CMD_MAP_QUEST_MARKERS_RETIRED": (
    "quest markers:       retired; hover an area for the quest",
    "marqueurs de quête : retirés ; survolez une zone pour la quête",
    "маркеры заданий:     сняты; наведите на область, чтобы увидеть задание",
    "任务标记：           已停用；将鼠标悬停在区域上查看任务"),
"CMD_MAP_VENDOR_PINS": (
    "quest vendor points: %s, %s on the map / %s on the minimap",
    "points marchands :   %s, %s sur la carte / %s sur la mini-carte",
    "точки торговцев:     %s, %s на карте / %s на миникарте",
    "任务商人点：         %s，地图 %s / 小地图 %s",
),
"CMD_MAP_BAGS": ("(bags: %s)", "(sacs : %s)", "(сумки: %s)", "（背包：%s）"),
"CMD_MAP_BAGS_UNREADABLE": ("unreadable", "illisibles", "нечитаемо", "无法读取"),
"CMD_MAP_OBJECTIVE_STYLE": (
    "objective style:     %s (/uq map dots|areas)",
    "style des objectifs : %s (/uq map dots|areas)",
    "стиль целей:         %s (/uq map dots|areas)",
    "目标样式：           %s（/uq map dots|areas）"),
"CMD_MAP_STYLE_DOTS": ("dots", "points", "точки", "圆点"),
"CMD_MAP_STYLE_AREAS": ("areas", "zones", "области", "区域"),
"CMD_MAP_OBJECTIVE_FRAMES": (
    "objective frames:    %s visible / %s pooled",
    "cadres d'objectif :  %s visibles / %s en réserve",
    "кадры целей:         %s видимых / %s в пуле",
    "目标框体：           %s 可见 / %s 已缓存"),
"CMD_MAP_COLOURS": (
    "map colours:          blue objectives / green turn-ins / gold patrols",
    "couleurs de carte :   objectifs bleus / rendus verts / patrouilles dorées",
    "цвета карты:          синие цели / зелёные сдачи / золотые патрули",
    "地图颜色：            蓝色目标 / 绿色交任务 / 金色巡逻"),
"CMD_MAP_COLOURS_MARKERS": (
    " + yellow numbered markers", " + marqueurs numérotés jaunes",
    " + жёлтые нумерованные маркеры", " + 黄色编号标记"),
"CMD_MAP_GIVER_MARKERS": (
    "giver \"!\" markers:   %s visible / %s pooled",
    "marqueurs \"!\" :      %s visibles / %s en réserve",
    "маркеры \"!\":         %s видимых / %s в пуле",
    "任务发布者“!”标记：  %s 可见 / %s 已缓存"),
"CMD_MAP_PATROL_TARGETS": (
    "patrol hover targets: %s visible / %s pooled",
    "cibles de survol des patrouilles : %s visibles / %s en réserve",
    "цели наведения патрулей: %s видимых / %s в пуле",
    "巡逻悬停目标：       %s 可见 / %s 已缓存"),
"CMD_MAP_PATROL_STROKES": (
    "patrol line stamps:  %s visible at %spx",
    "segments de patrouille : %s visibles à %s px",
    "штрихи линий патруля: %s видимых при %s px",
    "巡逻线段：           %s 可见，宽 %s 像素"),
"CMD_MAP_TURNIN_MARKERS": (
    "turn-in \"?\" markers: %s visible / %s pooled",
    "marqueurs \"?\" :      %s visibles / %s en réserve",
    "маркеры \"?\":         %s видимых / %s в пуле",
    "交任务“?”标记：      %s 可见 / %s 已缓存"),
"CMD_MAP_TURNIN_READY_ONLY": (
    "(ready-to-hand-in only)", "(prêtes à rendre uniquement)",
    "(только готовые к сдаче)", "（仅显示可交的）"),
"CMD_MAP_ITEM_USE_UNRESOLVED": (
    "item-use unresolved: %s", "objets à utiliser non résolus : %s",
    "неразрешённых целей с предметом: %s", "未解析的物品使用目标：%s"),
"CMD_MAP_AREA_HOVERS": (
    "area hovers seen:    %s", "survols de zone observés : %s",
    "наведений на область: %s", "观察到的区域悬停：   %s"),
"CMD_MAP_GIVER_HOVERS_CLICKS": (
    "giver hovers/clicks: %s / %s", "survols/clics sur \"!\" : %s / %s",
    "наведения/клики по \"!\": %s / %s", "“!”悬停/点击：      %s / %s"),
"CMD_MAP_TURNIN_HOVERS": (
    "turn-in hovers:      %s", "survols de \"?\" :    %s",
    "наведения на \"?\":   %s", "“?”悬停：            %s"),
"CMD_MAP_OVERLAY_REBUILDS": (
    "overlay rebuilds:    %s", "reconstructions de la surcouche : %s",
    "перестроений слоя:   %s", "覆盖层重建次数：     %s"),
"CMD_MAP_AREAS_UNAVAILABLE": (
    "quest areas:         unavailable", "zones de quête :     indisponibles",
    "области заданий:     недоступны", "任务区域：           不可用"),
"CMD_MAP_MARKER_COLOURS": (
    "marker colours:      yellow objectives / green turn-ins",
    "couleurs des marqueurs : objectifs jaunes / rendus verts",
    "цвета маркеров:      жёлтые цели / зелёные сдачи",
    "标记颜色：           黄色目标 / 绿色交任务"),

# --- minimap -----------------------------------------------------------------
"CMD_MINIMAP_PINS_ON": (
    "minimap quest pins on", "repères de quête de la mini-carte activés",
    "метки заданий на миникарте включены", "小地图任务标记已开启"),
"CMD_MINIMAP_PINS_OFF": (
    "minimap quest pins off", "repères de quête de la mini-carte désactivés",
    "метки заданий на миникарте выключены", "小地图任务标记已关闭"),
"CMD_MINIMAP_INDOORS_WITHHELD": (
    "minimap markers are withheld indoors",
    "les repères de la mini-carte sont masqués en intérieur",
    "метки миникарты скрываются в помещении",
    "室内不显示小地图标记"),
"CMD_MINIMAP_INDOORS_DRAWN": (
    "minimap markers are drawn indoors, at a scale this client cannot confirm",
    "les repères de la mini-carte sont dessinés en intérieur, à une échelle que ce "
    "client ne peut pas confirmer",
    "метки миникарты рисуются в помещении, в масштабе, который клиент подтвердить не может",
    "室内也绘制小地图标记，但比例无法由此客户端确认"),
"CMD_MINIMAP_SPAN_AT_ZOOM": (
    "minimap scale at zoom %s: %s yards across (%s)",
    "échelle de la mini-carte au zoom %s : %s mètres de large (%s)",
    "масштаб миникарты на зуме %s: %s ярдов в ширину (%s)",
    "缩放 %s 时的小地图比例：宽 %s 码（%s）"),
"CMD_MINIMAP_SPAN_HELP_SET": (
    "/uq minimap span <yards>   set the scale for this zoom step, here",
    "/uq minimap span <yards>   régler l'échelle pour ce niveau de zoom, ici",
    "/uq minimap span <yards>   задать масштаб для этого шага зума, здесь",
    "/uq minimap span <yards>   在此为该缩放级别设置比例"),
"CMD_MINIMAP_SPAN_HELP_RESET": (
    "/uq minimap span reset     go back to the built-in constant",
    "/uq minimap span reset     revenir à la constante intégrée",
    "/uq minimap span reset     вернуться к встроенной константе",
    "/uq minimap span reset     恢复为内置常量"),
"CMD_MINIMAP_SPAN_HELP_HINT": (
    "a marker that creeps WITH you means the number is too big",
    "un repère qui dérive AVEC vous signifie que le nombre est trop grand",
    "маркер, ползущий ВМЕСТЕ с вами, означает, что число слишком велико",
    "标记随你一起漂移说明数值过大"),
"CMD_MINIMAP_SPAN_USAGE": (
    "give a number of yards, or 'reset'",
    "indiquez un nombre de mètres, ou 'reset'",
    "укажите количество ярдов или 'reset'",
    "请给出码数，或输入 'reset'"),
"CMD_MINIMAP_SPAN_NO_ZOOM": (
    "the minimap zoom could not be read, so there is nothing to key this to",
    "le zoom de la mini-carte n'a pas pu être lu, il n'y a donc rien à quoi rattacher ceci",
    "зум миникарты прочитать не удалось, поэтому привязать значение не к чему",
    "无法读取小地图缩放级别，因此没有可关联的对象"),
"CMD_MINIMAP_SPAN_SET": (
    "minimap scale at zoom %s (%s): %s yards across (%s)",
    "échelle de la mini-carte au zoom %s (%s) : %s mètres de large (%s)",
    "масштаб миникарты на зуме %s (%s): %s ярдов в ширину (%s)",
    "缩放 %s（%s）时的小地图比例：宽 %s 码（%s）"),
"CMD_MINIMAP_ENVIRONMENT_UNKNOWN": (
    "environment unknown", "environnement inconnu",
    "окружение неизвестно", "环境未知"),
"CMD_MINIMAP_TITLE": (
    "minimap quest pins:", "repères de quête de la mini-carte :",
    "метки заданий на миникарте:", "小地图任务标记："),
"CMD_MINIMAP_SETTING": (
    "setting:        %s", "réglage :       %s", "настройка:      %s", "设置：          %s"),
"CMD_MINIMAP_STATE": (
    "state:          %s", "état :          %s", "состояние:      %s", "状态：          %s"),
"CMD_MINIMAP_DRAWN": (
    "drawn:          %s objectives, %s givers, %s turn-ins",
    "dessinés :      %s objectifs, %s donneurs, %s rendus",
    "нарисовано:     %s целей, %s выдающих, %s сдач",
    "已绘制：        %s 个目标，%s 个发布者，%s 个交付点"),
"CMD_MINIMAP_CLAMPED": (
    "clamped to edge: %s of %s", "collés au bord : %s sur %s",
    "прижато к краю: %s из %s", "固定在边缘：    %s / %s"),
"CMD_MINIMAP_WIDTH": (
    "minimap width:  %spx at zoom %s", "largeur mini-carte : %s px au zoom %s",
    "ширина миникарты: %s px при зуме %s", "小地图宽度：    %s 像素，缩放 %s"),
"CMD_MINIMAP_SCALE": (
    "scale:          %s yards across (%s)",
    "échelle :       %s mètres de large (%s)",
    "масштаб:        %s ярдов в ширину (%s)",
    "比例：          宽 %s 码（%s）"),
"CMD_MINIMAP_ONLY_ZOOM_ZERO": (
    "only zoom 0 is measured on this client; other steps use Vanilla constants",
    "seul le zoom 0 est mesuré sur ce client ; les autres niveaux utilisent les "
    "constantes Vanilla",
    "на этом клиенте измерен только зум 0; остальные шаги используют константы Vanilla",
    "此客户端仅测量了缩放级别 0；其他级别使用 Vanilla 常量"),
"CMD_MINIMAP_ROTATING": (
    "rotateMinimap is on: pins are hidden, this client exposes no player facing",
    "rotateMinimap est actif : les repères sont masqués, ce client n'expose aucune "
    "orientation du joueur",
    "rotateMinimap включён: метки скрыты, клиент не сообщает направление взгляда игрока",
    "rotateMinimap 已开启：标记被隐藏，此客户端不提供玩家朝向"),
"CMD_MINIMAP_SPAN_TIP": (
    "/uq minimap span <yards> dials this in where it is wrong",
    "/uq minimap span <yards> permet de l'ajuster là où c'est faux",
    "/uq minimap span <yards> подстраивает это там, где неверно",
    "/uq minimap span <yards> 可在不准确处进行微调"),
"CMD_MINIMAP_INDOORS_STATUS_WITHHELD": (
    "indoors:        markers withheld (the scale inside cannot be established here)",
    "intérieur :     repères masqués (l'échelle intérieure ne peut pas être établie ici)",
    "в помещении:    метки скрыты (масштаб внутри здесь установить нельзя)",
    "室内：          隐藏标记（此处无法确定室内比例）"),
"CMD_MINIMAP_INDOORS_STATUS_DRAWN": (
    "indoors:        markers drawn at the outdoor scale",
    "intérieur :     repères dessinés à l'échelle extérieure",
    "в помещении:    метки рисуются в наружном масштабе",
    "室内：          按室外比例绘制标记"),
"CMD_MINIMAP_PIN_FAILURES": (
    "pin failures:   %s", "échecs de repère : %s",
    "сбоев меток:    %s", "标记失败：      %s"),
"CMD_MINIMAP_PIN_CLICKS": (
    "pin clicks:     %s", "clics sur repère : %s",
    "кликов по меткам: %s", "标记点击：      %s"),
"CMD_MINIMAP_CLICKS_UNPROVEN": (
    "no pin click has been seen yet -- if clicking one does nothing, the minimap is keeping the click",
    "aucun clic sur un repère n'a encore été vu -- si cliquer ne fait rien, la minicarte garde le clic",
    "кликов по меткам ещё не было -- если клик ничего не делает, миникарта забирает его себе",
    "尚未检测到标记点击——若点击无反应，则说明小地图截留了点击"),

# --- database ----------------------------------------------------------------
"CMD_DB_WORLD_DATA": (
    "world data: %s", "données du monde : %s", "данные мира: %s", "世界数据：%s"),
"CMD_DB_TITLES_INDEXED": (
    "titles indexed: %s", "titres indexés : %s",
    "проиндексировано названий: %s", "已索引标题：%s"),
"CMD_DB_UNMATCHED": (
    "unmatched titles recorded: %s", "titres non appariés enregistrés : %s",
    "записано несопоставленных названий: %s", "已记录的未匹配标题：%s"),
"CMD_DB_NOT_LOADED": (
    "the bundled world data did not load; check the addon install",
    "les données du monde fournies n'ont pas été chargées ; vérifiez l'installation "
    "de l'addon",
    "встроенные данные мира не загрузились; проверьте установку аддона",
    "随附的世界数据未加载；请检查插件安装"),

# --- tooltip diagnostics -----------------------------------------------------
"CMD_TOOLTIP_TITLE": (
    "entity-tooltip objective diagnostics:",
    "diagnostics des objectifs d'infobulle d'entité :",
    "диагностика целей в подсказках существ:",
    "实体提示目标诊断："),
"CMD_TOOLTIP_REFRESH_CALLS": (
    "Refresh() calls seen:         %s", "appels Refresh() observés : %s",
    "вызовов Refresh():            %s", "观察到的 Refresh() 调用：%s"),
"CMD_TOOLTIP_NEVER_RAN": (
    "Refresh has never run -- the poll job or OnShow hook never fired",
    "Refresh n'a jamais été exécuté -- la tâche de sondage ou le hook OnShow ne s'est "
    "jamais déclenché",
    "Refresh ни разу не выполнялся -- задание опроса или хук OnShow не срабатывал",
    "Refresh 从未运行 -- 轮询任务或 OnShow 钩子从未触发"),
"CMD_TOOLTIP_FORMATS_RESOLVED": (
    "objective formats resolved:   %s / %s",
    "formats d'objectif résolus :  %s / %s",
    "разрешено форматов целей:     %s / %s",
    "已解析的目标格式：            %s / %s"),
"CMD_TOOLTIP_NO_FORMAT": (
    "no QUEST_MONSTERS_KILLED-style format string resolved; objective lines cannot be "
    "split into a name and counters",
    "aucune chaîne de format de type QUEST_MONSTERS_KILLED résolue ; les lignes "
    "d'objectif ne peuvent pas être séparées en nom et compteurs",
    "не разрешена ни одна строка формата вида QUEST_MONSTERS_KILLED; строки целей "
    "нельзя разделить на имя и счётчики",
    "未解析出 QUEST_MONSTERS_KILLED 类型的格式字符串；目标行无法拆分为名称和计数"),
"CMD_TOOLTIP_NAMES_READ": (
    "creature names read:          %s", "noms de créature lus :        %s",
    "прочитано имён существ:       %s", "已读取的生物名称：            %s"),
"CMD_TOOLTIP_LAST_TEXT": (
    "last tooltip text read:       %s", "dernier texte d'infobulle lu : %s",
    "последний прочитанный текст:  %s", "最后读取的提示文本：          %s"),
"CMD_TOOLTIP_NO_TEXT_RETURNED": (
    "Refresh ran but GameTooltipTextLeft1 never returned text -- identity, not matching",
    "Refresh s'est exécuté mais GameTooltipTextLeft1 n'a jamais renvoyé de texte -- "
    "c'est l'identification, pas l'appariement",
    "Refresh выполнялся, но GameTooltipTextLeft1 не вернул текст -- это опознание, "
    "а не сопоставление",
    "Refresh 已运行，但 GameTooltipTextLeft1 从未返回文本 -- 问题在识别，而非匹配"),
"CMD_TOOLTIP_MOUSEOVERS": (
    "quest-linked mouseovers seen: %s (%s from the log line, %s from world data)",
    "survols liés à une quête :    %s (%s depuis la ligne du journal, %s depuis les "
    "données du monde)",
    "наведений, связанных с заданиями: %s (%s из строки журнала, %s из данных мира)",
    "与任务相关的鼠标悬停：        %s（%s 来自日志行，%s 来自世界数据）"),
"CMD_TOOLTIP_NEVER_MATCHED": (
    "creature names were read but never matched a quest objective",
    "des noms de créature ont été lus mais n'ont jamais correspondu à un objectif",
    "имена существ читались, но ни разу не совпали с целью задания",
    "已读取生物名称，但从未与任务目标匹配"),
"CMD_TOOLTIP_PRESENTATION_FAILURES": (
    "panel display failures:       %s", "échecs d'affichage du panneau : %s",
    "сбоев отображения панели:     %s", "面板显示失败：                %s"),
"CMD_TOOLTIP_ALL_PRESENTATIONS_FAILED": (
    "every match failed to show its progress panel -- panel creation or display failed",
    "chaque correspondance a échoué à afficher son panneau de progression -- la création "
    "ou l'affichage du panneau a échoué",
    "для каждого совпадения не удалось показать панель прогресса -- сбой создания или "
    "отображения панели",
    "所有匹配都无法显示进度面板 -- 面板创建或显示失败"),
"CMD_TOOLTIP_CURRENT_UNIT": (
    "currently hovered unit key:   %s", "clé de l'unité survolée :     %s",
    "ключ существа под курсором:   %s", "当前悬停单位键：              %s"),

# --- marks -------------------------------------------------------------------
"CMD_MARKS_OFF": (
    "quest marks off. Only a marked creature you can still name -- your target or what "
    "you are hovering -- could be cleared; the rest keep their mark until you look at "
    "them again",
    "marques de quête désactivées. Seule une créature marquée que vous pouvez encore "
    "nommer -- votre cible ou celle que vous survolez -- a pu être effacée ; les autres "
    "gardent leur marque jusqu'à ce que vous les regardiez à nouveau",
    "метки заданий выключены. Снять удалось только с существа, которое можно назвать -- "
    "вашей цели или того, на кого наведён курсор; остальные сохранят метку, пока вы "
    "снова на них не посмотрите",
    "任务标记已关闭。只有仍能指名的已标记生物——你的目标或悬停对象——才被清除；"
    "其余的会保留标记，直到你再次看到它们"),
"CMD_MARKS_ON": (
    "quest marks on", "marques de quête activées",
    "метки заданий включены", "任务标记已开启"),
"CMD_MARKS_ICON_USAGE": (
    "icon takes 1-8: 1 star, 2 circle, 3 diamond, 4 triangle, 5 moon, 6 square, "
    "7 cross, 8 skull",
    "icon accepte 1-8 : 1 étoile, 2 cercle, 3 losange, 4 triangle, 5 lune, 6 carré, "
    "7 croix, 8 crâne",
    "icon принимает 1-8: 1 звезда, 2 круг, 3 ромб, 4 треугольник, 5 полумесяц, "
    "6 квадрат, 7 крест, 8 череп",
    "icon 取值 1-8：1 星星，2 圆圈，3 菱形，4 三角，5 月亮，6 方块，7 十字，8 骷髅"),
"CMD_MARKS_ICON_SET": (
    "quest creatures will be marked with the %s",
    "les créatures de quête seront marquées avec %s",
    "существа заданий будут помечены: %s",
    "任务生物将以“%s”标记"),
"CMD_MARKS_GROUP_USAGE": (
    "group takes on or off", "group accepte on ou off",
    "group принимает on или off", "group 取值 on 或 off"),
"CMD_MARKS_GROUP_ON": (
    "quest creatures may be marked while grouped. The server rejected the solo case; "
    "group leader or raid assistant remains the only unverified route. Everyone sees "
    "these marks and they overwrite whatever your group had set",
    "les créatures de quête peuvent être marquées en groupe. Le serveur a refusé le cas "
    "en solo ; chef de groupe ou assistant de raid reste la seule voie non vérifiée. "
    "Tout le monde voit ces marques et elles écrasent celles posées par votre groupe",
    "существ заданий можно помечать в группе. Сервер отклонил одиночный случай; "
    "лидер группы или помощник рейда -- единственный непроверенный путь. Эти метки "
    "видят все, и они перезаписывают то, что установила ваша группа",
    "组队时可以标记任务生物。服务器拒绝了单人标记；队长或团队助理仍是唯一未经验证的"
    "途径。所有人都能看到这些标记，且会覆盖你队伍已设置的标记"),
"CMD_MARKS_GROUP_OFF": (
    "group quest marks off; solo marks are unavailable on this realm",
    "marques de quête en groupe désactivées ; les marques en solo sont indisponibles "
    "sur ce royaume",
    "групповые метки заданий выключены; одиночные метки на этом сервере недоступны",
    "组队任务标记已关闭；此服务器上不支持单人标记"),
"CMD_MARKS_TITLE": (
    "quest marks over creatures:", "marques de quête sur les créatures :",
    "метки заданий над существами:", "生物头顶的任务标记："),
"CMD_MARKS_UNAVAILABLE": (
    "SetRaidTarget/GetRaidTargetIndex are not callable here; nothing can be drawn over "
    "a creature on this client at all",
    "SetRaidTarget/GetRaidTargetIndex ne sont pas appelables ici ; rien ne peut être "
    "dessiné au-dessus d'une créature sur ce client",
    "SetRaidTarget/GetRaidTargetIndex здесь недоступны; на этом клиенте над существом "
    "вообще ничего нельзя нарисовать",
    "此处无法调用 SetRaidTarget/GetRaidTargetIndex；在此客户端上完全无法在生物上方绘制任何东西"),
"CMD_MARKS_ENABLED": (
    "enabled:                 %s", "activé :                 %s",
    "включено:                %s", "已启用：                 %s"),
"CMD_MARKS_MARK_USED": (
    "mark used:               %s for objectives, %s for turn-ins",
    "marque utilisée :        %s pour les objectifs, %s pour les rendus",
    "используемая метка:      %s для целей, %s для сдач",
    "使用的标记：             目标用 %s，交任务用 %s"),
"CMD_MARKS_IN_GROUP": (
    "in a group:              %s", "en groupe :              %s",
    "в группе:                %s", "在队伍中：               %s"),
"CMD_MARKS_PAUSED": (
    "-- paused; /uq marks group on", "-- en pause ; /uq marks group on",
    "-- приостановлено; /uq marks group on", "-- 已暂停；/uq marks group on"),
"CMD_MARKS_SOLO_REFUSED": (
    "-- unavailable: this realm ignored every solo write",
    "-- indisponible : ce royaume a ignoré chaque écriture en solo",
    "-- недоступно: этот сервер проигнорировал все одиночные записи",
    "-- 不可用：此服务器忽略了所有单人写入"),
"CMD_MARKS_WRITTEN": (
    "marks written:           %s, confirmed %s, cleared %s",
    "marques écrites :        %s, confirmées %s, effacées %s",
    "меток записано:          %s, подтверждено %s, снято %s",
    "已写入标记：             %s，已确认 %s，已清除 %s"),
"CMD_MARKS_LAST_MARKED": (
    "last marked:             %s", "dernière marquée :       %s",
    "последняя метка:         %s", "最近标记：               %s"),
"CMD_MARKS_SOLO_NOTE": (
    "no persistent 3D quest marker is available while solo. The only remaining test is "
    "as party leader or raid assistant: /uq marks group on",
    "aucun marqueur 3D persistant n'est disponible en solo. Le seul test restant est en "
    "tant que chef de groupe ou assistant de raid : /uq marks group on",
    "в одиночку постоянный 3D-маркер задания недоступен. Остаётся проверить только в "
    "роли лидера группы или помощника рейда: /uq marks group on",
    "单人时无法使用持久的 3D 任务标记。唯一剩下的测试是作为队长或团队助理："
    "/uq marks group on"),
"CMD_MARKS_REFUSED_NOTE": (
    "the server never confirmed a single mark, so it is refusing them -- this group role "
    "may not be allowed to mark. Stopped trying for this session; /uq marks on retries",
    "le serveur n'a confirmé aucune marque, il les refuse donc -- ce rôle de groupe n'a "
    "peut-être pas le droit de marquer. Abandon pour cette session ; /uq marks on réessaie",
    "сервер не подтвердил ни одной метки, значит он их отклоняет -- возможно, эта роль в "
    "группе не может ставить метки. Попытки прекращены на эту сессию; /uq marks on повторит",
    "服务器从未确认过任何标记，说明它拒绝了这些标记 -- 该队伍身份可能无权标记。"
    "本次会话已停止尝试；/uq marks on 可重试"),
"CMD_MARKS_UNCONFIRMED_NOTE": (
    "written but not confirmed yet. SetRaidTarget sends the value to the server, so a "
    "mark takes a round trip to read back -- give it a few seconds",
    "écrites mais pas encore confirmées. SetRaidTarget envoie la valeur au serveur, une "
    "marque nécessite donc un aller-retour pour être relue -- patientez quelques secondes",
    "записано, но ещё не подтверждено. SetRaidTarget отправляет значение на сервер, "
    "поэтому метка читается обратно после обмена -- подождите несколько секунд",
    "已写入但尚未确认。SetRaidTarget 会把值发送到服务器，因此读回标记需要一次往返 "
    "-- 请等待几秒"),
"CMD_MARKS_ACCEPTED_NOTE": (
    "the server accepts these marks. Hover or target a quest creature and it gets one",
    "le serveur accepte ces marques. Survolez ou ciblez une créature de quête et elle "
    "en reçoit une",
    "сервер принимает эти метки. Наведите курсор или возьмите в цель существо задания -- "
    "и оно её получит",
    "服务器接受这些标记。悬停或选中任务生物即可为其添加标记"),

# --- world scan --------------------------------------------------------------
"CMD_WORLDSCAN_NO_CHILD": (
    "no WorldFrame child at index %s",
    "aucun enfant de WorldFrame à l'index %s",
    "нет дочернего объекта WorldFrame с индексом %s",
    "索引 %s 处没有 WorldFrame 子对象"),
"CMD_WORLDSCAN_SUMMARY": (
    "WorldFrame has %s children; %s inventoried.",
    "WorldFrame a %s enfants ; %s inventoriés.",
    "У WorldFrame %s дочерних объектов; перечислено %s.",
    "WorldFrame 有 %s 个子对象；已清点 %s 个。"),
"CMD_WORLDSCAN_SAVED_NOTE": (
    "saved to UnrealQuestDB.worldFrameScan -- /reload to flush it to disk, then read the "
    "file. Deliberately not printed here: 26 lines of it crashed this client",
    "enregistré dans UnrealQuestDB.worldFrameScan -- /reload pour l'écrire sur disque, "
    "puis lisez le fichier. Volontairement pas affiché ici : 26 lignes ont fait planter "
    "ce client",
    "сохранено в UnrealQuestDB.worldFrameScan -- /reload, чтобы записать на диск, затем "
    "прочитайте файл. Специально не выводится сюда: 26 строк обрушили этот клиент",
    "已保存至 UnrealQuestDB.worldFrameScan -- 输入 /reload 写入磁盘后再读取文件。"
    "此处刻意不打印：其中 26 行曾使此客户端崩溃"),

# --- find / tracking ---------------------------------------------------------
"CMD_FIND_USAGE": (
    "usage: /uq track <index or title fragment>",
    "usage : /uq track <index ou fragment de titre>",
    "использование: /uq track <индекс или часть названия>",
    "用法：/uq track <序号或标题片段>"),
"CMD_FIND_NO_INDEX": (
    "no quest at log index %s; use /uq quests to see available quests",
    "aucune quête à l'index %s du journal ; utilisez /uq quests pour voir les quêtes "
    "disponibles",
    "нет задания с индексом %s в журнале; используйте /uq quests, чтобы увидеть доступные",
    "日志序号 %s 处没有任务；使用 /uq quests 查看可用任务"),
"CMD_FIND_ENTER_TARGET": (
    "enter a quest index or title fragment",
    "saisissez un index de quête ou un fragment de titre",
    "введите индекс задания или часть названия",
    "请输入任务序号或标题片段"),
"CMD_FIND_NO_TITLE_MATCH": (
    "no quest title matches '%s'; use /uq quests to see available quests",
    "aucun titre de quête ne correspond à '%s' ; utilisez /uq quests pour voir les "
    "quêtes disponibles",
    "ни одно название задания не совпадает с «%s»; используйте /uq quests",
    "没有任务标题匹配“%s”；使用 /uq quests 查看可用任务"),
"CMD_FIND_AMBIGUOUS": (
    "'%s' matches several quests; use its index:",
    "'%s' correspond à plusieurs quêtes ; utilisez son index :",
    "«%s» совпадает с несколькими заданиями; укажите индекс:",
    "“%s”匹配多个任务；请使用其序号："),
"CMD_TRACK_ALREADY": (
    "already tracking '%s'", "'%s' est déjà suivie",
    "«%s» уже отслеживается", "已在追踪“%s”"),
"CMD_TRACK_NOT_TRACKED": (
    "'%s' is not tracked", "'%s' n'est pas suivie",
    "«%s» не отслеживается", "“%s”未被追踪"),
"CMD_TRACK_UNCHANGED": (
    "UnrealQuest did not update tracking for '%s'",
    "UnrealQuest n'a pas mis à jour le suivi de '%s'",
    "UnrealQuest не обновил отслеживание для «%s»",
    "UnrealQuest 未更新“%s”的追踪状态"),
"CMD_TRACK_NOW_TRACKING": (
    "tracking '%s'", "suivi de '%s'", "отслеживается «%s»", "正在追踪“%s”"),
"CMD_TRACK_STOPPED": (
    "stopped tracking '%s'", "'%s' n'est plus suivie",
    "отслеживание «%s» прекращено", "已停止追踪“%s”"),

# --- map visibility ----------------------------------------------------------
"CMD_HIDE_NO_QUEST_ID": (
    "'%s' has no resolved quest id to hide",
    "'%s' n'a pas d'identifiant de quête résolu à masquer",
    "у «%s» нет определённого идентификатора задания, который можно скрыть",
    "“%s”没有可隐藏的已解析任务 ID"),
"CMD_HIDE_DONE": (
    "hiding map pins for '%s'", "masquage des repères de '%s'",
    "метки карты для «%s» скрыты", "已隐藏“%s”的地图标记"),
"CMD_UNHIDE_DONE": (
    "restored map pins for '%s'", "repères de '%s' restaurés",
    "метки карты для «%s» восстановлены", "已恢复“%s”的地图标记"),
"CMD_HIDE_NOT_PERSISTED": (
    "could not persist that change for '%s'",
    "impossible d'enregistrer ce changement pour '%s'",
    "не удалось сохранить это изменение для «%s»",
    "无法为“%s”保存该更改"),
"CMD_HIDDEN_TITLE": (
    "quests hidden from the map:", "quêtes masquées de la carte :",
    "задания, скрытые с карты:", "已从地图隐藏的任务："),
"CMD_HIDDEN_BY_DEFAULT": ("(default)", "(par défaut)", "(по умолчанию)", "（默认）"),
"CMD_HIDDEN_NONE": (
    "no quests are hidden from the map", "aucune quête n'est masquée de la carte",
    "с карты не скрыто ни одного задания", "没有任务被从地图隐藏"),

# --- reset marked ------------------------------------------------------------
"CMD_RESETMARKED_NONE_MANUAL": (
    "no quests were marked done through shift/Ctrl-click since this tracking was added",
    "aucune quête n'a été marquée terminée par Maj/Ctrl+clic depuis l'ajout de ce suivi",
    "с момента появления этого учёта ни одно задание не отмечалось выполненным по "
    "Shift/Ctrl+клику",
    "自添加该记录功能以来，没有任务通过 Shift/Ctrl+点击被标记为已完成"),
"CMD_RESETMARKED_TRY_ALL": (
    "there are marked-done quests recorded from before that -- /uq resetmarked all "
    "clears those too",
    "des quêtes marquées terminées ont été enregistrées avant cela -- "
    "/uq resetmarked all les efface aussi",
    "есть задания, отмеченные выполненными ещё раньше -- /uq resetmarked all снимет и их",
    "在此之前记录过被标记为已完成的任务 -- /uq resetmarked all 也会清除它们"),
"CMD_RESETMARKED_NONE": (
    "no marked-done quests to reset",
    "aucune quête marquée terminée à réinitialiser",
    "нет отмеченных выполненными заданий для сброса",
    "没有可重置的“已完成”标记任务"),

# --- pfQuest command ---------------------------------------------------------
"CMD_PFQUEST_UNDO_NOTHING": (
    "no quests were imported from pfQuest, so there is nothing to take back",
    "aucune quête n'a été importée depuis pfQuest, il n'y a donc rien à annuler",
    "из pfQuest ничего не импортировалось, поэтому отменять нечего",
    "没有从 pfQuest 导入过任务，因此无可撤回"),
"CMD_PFQUEST_UNDO_LEFT_ALONE": (
    "quests marked done by this addon itself, or by hand, were left alone",
    "les quêtes marquées terminées par l'addon lui-même, ou à la main, n'ont pas été touchées",
    "задания, отмеченные самим аддоном или вручную, остались нетронутыми",
    "由本插件自身或手动标记为完成的任务未受影响"),
"CMD_PFQUEST_UNKNOWN_OPTION": (
    "unknown option: %s -- use /uq pfquest, /uq pfquest import or /uq pfquest undo",
    "option inconnue : %s -- utilisez /uq pfquest, /uq pfquest import ou /uq pfquest undo",
    "неизвестный параметр: %s -- используйте /uq pfquest, /uq pfquest import или "
    "/uq pfquest undo",
    "未知选项：%s -- 请使用 /uq pfquest、/uq pfquest import 或 /uq pfquest undo"),
"CMD_PFQUEST_HINT_READY": (
    "/uq pfquest import marks those quests done here",
    "/uq pfquest import marque ces quêtes comme terminées ici",
    "/uq pfquest import отметит эти задания выполненными здесь",
    "/uq pfquest import 会在此处将这些任务标记为已完成"),
"CMD_PFQUEST_HINT_DISABLED_1": (
    "/uq pfquest import switches pfQuest on for one reload, imports, and",
    "/uq pfquest import active pfQuest pour un rechargement, importe, puis",
    "/uq pfquest import включит pfQuest на одну перезагрузку, импортирует и",
    "/uq pfquest import 会为一次重载启用 pfQuest，完成导入后"),
"CMD_PFQUEST_HINT_DISABLED_2": (
    "switches it back off -- this client will not let an addon reload for you",
    "le désactive -- ce client ne laisse pas un addon recharger à votre place",
    "снова выключит его -- этот клиент не позволяет аддону перезагрузиться за вас",
    "再将其关闭 -- 此客户端不允许插件替你重载"),
"CMD_PFQUEST_HINT_PENDING": (
    "type /reload -- the import is waiting for it",
    "tapez /reload -- l'import l'attend",
    "введите /reload -- импорт ждёт этого",
    "请输入 /reload -- 导入正在等待"),
"CMD_PFQUEST_UNDO_HINT": (
    "/uq pfquest undo takes back everything an import added",
    "/uq pfquest undo annule tout ce qu'un import a ajouté",
    "/uq pfquest undo отменит всё, что добавил импорт",
    "/uq pfquest undo 可撤回导入添加的全部内容"),

# --- tracker command ---------------------------------------------------------
"CMD_TRACKER_SHOWN": (
    "quest tracker shown", "suivi de quêtes affiché",
    "трекер заданий показан", "任务追踪器已显示"),
"CMD_TRACKER_HIDDEN": (
    "quest tracker hidden", "suivi de quêtes masqué",
    "трекер заданий скрыт", "任务追踪器已隐藏"),
"CMD_TRACKER_RESET_DONE": (
    "quest tracker moved back to its default position",
    "suivi de quêtes replacé à sa position par défaut",
    "трекер заданий возвращён в положение по умолчанию",
    "任务追踪器已移回默认位置"),
"CMD_TRACKER_OBJECTIVES_USAGE": (
    "usage: /uq tracker objectives all|tracked|none",
    "usage : /uq tracker objectives all|tracked|none",
    "использование: /uq tracker objectives all|tracked|none",
    "用法：/uq tracker objectives all|tracked|none"),
"CMD_TRACKER_OBJECTIVES_SET": (
    "tracker objectives: %s", "objectifs du suivi : %s",
    "цели в трекере: %s", "追踪器目标：%s"),
"CMD_TRACKER_ZONES_SET": (
    "tracker zone headers %s", "en-têtes de zone du suivi : %s",
    "заголовки зон в трекере: %s", "追踪器区域标题：%s"),
"CMD_TRACKER_RECENT_SET": (
    "tracker lifts the quest that just advanced %s",
    "remontée de la quête qui vient d'avancer : %s",
    "подъём задания с новым прогрессом: %s",
    "将刚有进展的任务置顶：%s"),
"CMD_TRACKER_NATIVE_HIDDEN": (
    "native quest watch panel hidden", "panneau de suivi natif masqué",
    "родная панель слежения скрыта", "原生任务监视面板已隐藏"),
"CMD_TRACKER_NATIVE_SHOWN": (
    "native quest watch panel shown", "panneau de suivi natif affiché",
    "родная панель слежения показана", "原生任务监视面板已显示"),
"CMD_TRACKER_NATIVE_TIMER_NOTE": (
    "the client re-shows it on its own, so it is hidden again on a timer",
    "le client le réaffiche de lui-même, il est donc re-masqué par une minuterie",
    "клиент показывает её снова сам, поэтому она скрывается по таймеру",
    "客户端会自行重新显示它，因此会按计时器再次隐藏"),
"CMD_TRACKER_WIDTH_USAGE": (
    "usage: /uq tracker width <110-600>", "usage : /uq tracker width <110-600>",
    "использование: /uq tracker width <110-600>", "用法：/uq tracker width <110-600>"),
"CMD_TRACKER_WIDTH_SET": (
    "tracker width: %s", "largeur du suivi : %s",
    "ширина трекера: %s", "追踪器宽度：%s"),
"CMD_TRACKER_HEIGHT_USAGE": (
    "usage: /uq tracker height <60-900>, or 0 for no limit",
    "usage : /uq tracker height <60-900>, ou 0 pour aucune limite",
    "использование: /uq tracker height <60-900> или 0 без ограничения",
    "用法：/uq tracker height <60-900>，0 表示不限"),
"CMD_TRACKER_HEIGHT_NONE": (
    "tracker max height: none (grows with the log)",
    "hauteur max du suivi : aucune (croît avec le journal)",
    "макс. высота трекера: без ограничения (растёт вместе с журналом)",
    "追踪器最大高度：无（随日志增长）"),
"CMD_TRACKER_HEIGHT_SET": (
    "tracker max height: %spx", "hauteur max du suivi : %s px",
    "макс. высота трекера: %s px", "追踪器最大高度：%s 像素"),
"CMD_TRACKER_UNFOLD_DONE": (
    "every folded quest and zone reopened",
    "toutes les quêtes et zones repliées ont été rouvertes",
    "все свёрнутые задания и зоны раскрыты",
    "所有折叠的任务和区域已展开"),
"CMD_TRACKER_UNHIDEALL_DONE": (
    "every quest untracked out of the tracker is back",
    "toutes les quêtes retirées du suivi sont revenues",
    "все задания, убранные из трекера, возвращены",
    "所有被移出追踪器的任务已恢复"),
"CMD_TRACKER_UNKNOWN": (
    "unknown tracker command: %s", "commande de suivi inconnue : %s",
    "неизвестная команда трекера: %s", "未知的追踪器命令：%s"),
"CMD_TRACKER_TITLE": (
    "quest tracker window", "fenêtre de suivi de quêtes",
    "окно трекера заданий", "任务追踪器窗口"),
"CMD_TRACKER_NOT_CREATED": (
    "the window could not be created on this client",
    "la fenêtre n'a pas pu être créée sur ce client",
    "окно не удалось создать на этом клиенте",
    "无法在此客户端创建该窗口"),
"CMD_TRACKER_STATE_SHOWN": ("shown", "affichée", "показано", "已显示"),
"CMD_TRACKER_STATE_HIDDEN": ("hidden", "masquée", "скрыто", "已隐藏"),
"CMD_TRACKER_STATE_FOLDED": (
    "folded to the title bar", "repliée sur la barre de titre",
    "свёрнуто до заголовка", "已折叠到标题栏"),
"CMD_TRACKER_HEIGHT_AUTO": ("auto", "auto", "авто", "自动"),
"CMD_TRACKER_HEIGHT_MAX": ("%s max", "%s max", "%s макс.", "最大 %s"),
"CMD_TRACKER_POSITION": (
    "position %s %s (UIParent)", "position %s %s (UIParent)",
    "позиция %s %s (UIParent)", "位置 %s %s（UIParent）"),
"CMD_TRACKER_DRAG_REFUSED": (
    "StartMoving was refused -- see docs/QUEST-TRACKER.md",
    "StartMoving a été refusé -- voir docs/QUEST-TRACKER.md",
    "StartMoving отклонён -- см. docs/QUEST-TRACKER.md",
    "StartMoving 被拒绝 -- 见 docs/QUEST-TRACKER.md"),

# --- feature gate ------------------------------------------------------------
"CMD_FEATURE_DISABLED_TITLE": (
    "the main quest + HUD waypoint layer is %s in this build",
    "la couche quête principale + repère ATH est %s dans cette version",
    "слой главного задания и маркера HUD %s в этой сборке",
    "主线任务 + HUD 路径点层在此版本中%s"),
"CMD_FEATURE_DISABLED_1": (
    "the code is still in the addon, but it registers nothing: no driver jobs, no click "
    "chains on the quest log, no marker frame.",
    "le code est toujours dans l'addon, mais il n'enregistre rien : aucune tâche, aucune "
    "chaîne de clic sur le journal, aucun cadre de marqueur.",
    "код по-прежнему в аддоне, но он ничего не регистрирует: ни заданий драйвера, ни "
    "цепочек кликов в журнале, ни кадра маркера.",
    "代码仍在插件中，但它不注册任何东西：没有驱动任务，没有任务日志点击链，没有标记框体。"),
"CMD_NAV_TITLE": (
    "quest navigator:",
    "navigateur de quete :",
    "навигатор заданий:",
    "任务导航："),
"CMD_NAV_HIDDEN": (
    "hidden: %s",
    "masque : %s",
    "скрыт: %s",
    "已隐藏：%s"),
"CMD_NAV_HIDDEN_REASONS": (
    "reasons it stayed hidden:",
    "raisons pour lesquelles il est reste masque :",
    "причины, по которым он оставался скрытым:",
    "保持隐藏的原因："),
"CMD_NAV_NO_ROTATION": (
    "this client refused to rotate a texture, so the arrow cannot turn",
    "ce client a refuse de faire pivoter une texture, la fleche ne peut donc pas tourner",
    "этот клиент отказался повернуть текстуру, поэтому стрелка не может вращаться",
    "此客户端拒绝旋转贴图，因此箭头无法转动"),
"CMD_FEATURE_DISABLED_2": (
    "the layer is on by default, so something switched it off by hand. It needs a readable "
    "player facing to aim the marker. See docs/HUD-WAYPOINT.md.",
    "cette couche est active par défaut : elle a donc été désactivée à la main. Elle a besoin "
    "d'une orientation du joueur lisible pour viser le marqueur. Voir docs/HUD-WAYPOINT.md.",
    "этот слой включён по умолчанию, значит его отключили вручную. Ему нужно "
    "читаемое направление игрока, чтобы навести маркер. См. docs/HUD-WAYPOINT.md.",
    "该模块默认开启，因此它是被手动关闭的。它需要可读取的玩家朝向才能对准标记。"
    "见 docs/HUD-WAYPOINT.md。"),
"CMD_FEATURE_DISABLED_3": (
    "to re-enable: set the mainQuestWaypoint feature to true in Core/Namespace.lua, "
    "then /reload.",
    "pour réactiver : passez la fonctionnalité mainQuestWaypoint à true dans "
    "Core/Namespace.lua, puis /reload.",
    "чтобы включить обратно: установите функцию mainQuestWaypoint в true в "
    "Core/Namespace.lua и выполните /reload.",
    "如需重新启用：在 Core/Namespace.lua 中将 mainQuestWaypoint 功能设为 true，"
    "然后 /reload。"),

# --- main quest --------------------------------------------------------------
"CMD_MAIN_NOT_FOLLOWING": (
    "not following any quest", "aucune quête suivie",
    "ни за одним заданием не следуем", "未跟随任何任务"),
"CMD_MAIN_HOW_TO_FOLLOW": (
    "click a quest in the quest log or the tracker, or /uq main <index or title>",
    "cliquez une quête dans le journal ou le suivi, ou /uq main <index ou titre>",
    "щёлкните задание в журнале или трекере либо введите /uq main <индекс или название>",
    "在任务日志或追踪器中点击一个任务，或使用 /uq main <序号或标题>"),
"CMD_MAIN_FOLLOWING": (
    "following: %s", "suivi : %s", "следуем за: %s", "正在跟随：%s"),
"CMD_MAIN_DETAIL": (
    "quest log index %s, level %s, match %s",
    "index du journal %s, niveau %s, correspondance %s",
    "индекс журнала %s, уровень %s, совпадение %s",
    "任务日志序号 %s，等级 %s，匹配 %s"),
"CMD_MAIN_READY_TO_HAND_IN": (
    "ready to hand in; the waypoint points at the turn-in",
    "prête à rendre ; le repère pointe vers le point de rendu",
    "готово к сдаче; маркер указывает на место сдачи",
    "可以交任务了；路径点指向交付处"),
"CMD_MAIN_NOT_IN_LOG": (
    "not currently in the quest log", "absente du journal de quêtes actuellement",
    "сейчас отсутствует в журнале заданий", "当前不在任务日志中"),
"CMD_MAIN_REMEMBERED_AS": (
    "(remembered as '%s')", "(mémorisée sous '%s')",
    "(запомнено как «%s»)", "（记为“%s”）"),
"CMD_MAIN_CLICK_SURFACES": (
    "tracker click surface: %s lines mapped",
    "surface de clic du suivi : %s lignes mappees",
    "поверхность кликов трекера: сопоставлено строк: %s",
    "追踪器点击面：已映射 %s 行"),
"CMD_MAIN_CLICKS_SEEN": (
    "tracker clicks seen: %s; modifier=%s",
    "clics du suivi observes : %s ; modificateur=%s",
    "кликов трекера замечено: %s; модификатор=%s",
    "观察到的追踪器点击：%s 次；修饰键=%s"),
"CMD_MAIN_AMBIGUOUS": (
    "'%s' matches several quests:", "'%s' correspond à plusieurs quêtes :",
    "«%s» совпадает с несколькими заданиями:", "“%s”匹配多个任务："),
"CMD_MAIN_NO_INDEX": (
    "no quest at quest log index %s", "aucune quête à l'index %s du journal",
    "нет задания с индексом %s в журнале", "任务日志序号 %s 处没有任务"),
"CMD_MAIN_NO_MATCH": (
    "no quest in the log matches '%s'",
    "aucune quête du journal ne correspond à '%s'",
    "ни одно задание в журнале не совпадает с «%s»",
    "日志中没有任务匹配“%s”"),

# --- waypoint ----------------------------------------------------------------
"CMD_WAYPOINT_TITLE": (
    "HUD waypoint marker", "repère ATH", "маркер HUD", "HUD 路径点标记"),
"CMD_WAYPOINT_DISTANCE": (
    "distance %s yd, clamped=%s, area %s",
    "distance %s m, collé=%s, zone %s",
    "расстояние %s м, прижат=%s, зона %s",
    "距离 %s 码，已贴边=%s，区域 %s"),
"CMD_WAYPOINT_HIDDEN": (
    "hidden: %s", "masqué : %s", "скрыт: %s", "已隐藏：%s"),
"CMD_WAYPOINT_HIDDEN_REASONS": (
    "hidden reasons seen:", "raisons de masquage observées :",
    "замеченные причины скрытия:", "观察到的隐藏原因："),
"CMD_WAYPOINT_FACING": (
    "facing: %s via %s", "orientation : %s via %s",
    "направление: %s через %s", "朝向：%s，来源 %s"),
"CMD_WAYPOINT_STALE": ("(stale)", "(périmée)", "(устарело)", "（已过期）"),
"CMD_WAYPOINT_HEADING_COUNTS": (
    "heading samples=%s movement fixes=%s client source=%s",
    "échantillons de cap=%s corrections de mouvement=%s source client=%s",
    "выборок курса=%s поправок по движению=%s источник клиента=%s",
    "航向采样=%s 移动修正=%s 客户端来源=%s"),
"CMD_WAYPOINT_NO_FACING_SOURCE": (
    "no facing source", "aucune source d'orientation",
    "нет источника направления", "没有朝向来源"),
"CMD_WAYPOINT_NO_FACING_HINT": (
    "run /urp probe facing, turn a full circle, then /urp probe facing stop",
    "lancez /urp probe facing, faites un tour complet, puis /urp probe facing stop",
    "выполните /urp probe facing, сделайте полный оборот, затем /urp probe facing stop",
    "运行 /urp probe facing，原地转一整圈，然后 /urp probe facing stop"),

# --- quest log dump / config -------------------------------------------------
"CMD_QUESTLOG_DUMP_USAGE": (
    "open the quest log and select a quest first",
    "ouvrez d'abord le journal de quêtes et sélectionnez une quête",
    "сначала откройте журнал заданий и выберите задание",
    "请先打开任务日志并选择一个任务"),
"CMD_CONFIG_UNREALUI_BUTTON": (
    "unrealUI's own settings button is already beside the minimap and opens this page",
    "le bouton de réglages d'unrealUI est déjà à côté de la mini-carte et ouvre cette page",
    "собственная кнопка настроек unrealUI уже стоит рядом с миникартой и открывает эту страницу",
    "unrealUI 自己的设置按钮已在小地图旁，并会打开此页面"),
"CMD_CONFIG_BUTTON_SHOWN": (
    "the settings button beside the minimap is shown (%s)",
    "le bouton de réglages à côté de la mini-carte est affiché (%s)",
    "кнопка настроек рядом с миникартой показана (%s)",
    "小地图旁的设置按钮已显示（%s）"),
"CMD_CONFIG_BUTTON_HIDDEN": (
    "the settings button beside the minimap is hidden",
    "le bouton de réglages à côté de la mini-carte est masqué",
    "кнопка настроек рядом с миникартой скрыта",
    "小地图旁的设置按钮已隐藏"),
"CMD_CONFIG_WINDOW_FAILED": (
    "the options window could not be opened; every option is still on /uq",
    "la fenêtre d'options n'a pas pu être ouverte ; toutes les options restent sur /uq",
    "окно настроек не удалось открыть; все параметры по-прежнему доступны через /uq",
    "无法打开选项窗口；所有选项仍可通过 /uq 使用"),

# --- /uq rare ----------------------------------------------------------------
"CMD_MODULE_MISSING_RARE": (
    u"the rare alert module is not loaded",
    u"le module d'alerte rare n'est pas chargé",
    u"модуль оповещения о редких не загружен",
    u"稀有提醒模块未加载",
),
"CMD_MODULE_MISSING_ANNOUNCE": (
    u"the objective announcement module is not loaded",
    u"le module d'annonce des objectifs n'est pas chargé",
    u"модуль объявления целей не загружен",
    u"目标播报模块未加载",
),
"CMD_ANNOUNCE_TITLE": (
    u"objective progress in party chat:",
    u"progression des objectifs en chat de groupe :",
    u"прогресс целей в чате группы:",
    u"小队频道目标进度：",
),
"CMD_ANNOUNCE_SETTING": (
    u"report: %s",
    u"annonce : %s",
    u"отчёт: %s",
    u"播报：%s",
),
"CMD_ANNOUNCE_CHANNEL": (
    u"channel: %s",
    u"canal : %s",
    u"канал: %s",
    u"频道：%s",
),
"CMD_ANNOUNCE_SOURCE": (
    u"shared-quest check: %s",
    u"vérification de quête commune : %s",
    u"проверка общего задания: %s",
    u"共同任务检查：%s",
),
"CMD_ANNOUNCE_SOURCE_CLIENT": (
    u"the client's own, for every party member",
    u"celle du client, pour chaque membre du groupe",
    u"самого клиента, для всех участников",
    u"客户端自带，适用于所有队友",
),
"CMD_ANNOUNCE_SOURCE_PEERS": (
    u"other UnrealQuest members only",
    u"seulement les membres avec UnrealQuest",
    u"только участники с UnrealQuest",
    u"仅限使用 UnrealQuest 的队友",
),
"CMD_ANNOUNCE_PEERS": (
    u"group members running UnrealQuest: %s (%s quests known)",
    u"membres du groupe avec UnrealQuest : %s (%s quêtes connues)",
    u"участников с UnrealQuest: %s (известно заданий: %s)",
    u"使用 UnrealQuest 的队友：%s（已知任务 %s）",
),
"CMD_ANNOUNCE_PEER": (
    u"%s: %s quests",
    u"%s : %s quêtes",
    u"%s: заданий: %s",
    u"%s：%s 个任务",
),
"CMD_ANNOUNCE_UNSHARED": (
    u"%s steps stayed quiet: nobody in the group has that quest",
    u"%s étapes non annoncées : personne dans le groupe n'a cette quête",
    u"шагов без объявления: %s -- в группе никто не взял это задание",
    u"%s 次进度未播报：小队里没人接了那个任务",
),
"CMD_ANNOUNCE_RELAYED": (
    u"%s lines went to UnrealQuest party members, %s arrived from them",
    u"%s lignes envoyées aux membres avec UnrealQuest, %s reçues d'eux",
    u"отправлено участникам с UnrealQuest: %s, получено от них: %s",
    u"向 UnrealQuest 队友发送 %s 条，收到 %s 条",
),
"CMD_ANNOUNCE_NO_PEERS": (
    u"nobody in the group is running UnrealQuest with this option on, so nothing is sent",
    u"personne dans le groupe n'utilise UnrealQuest avec cette option : rien n'est envoyé",
    u"в группе никто не включил эту опцию в UnrealQuest, поэтому ничего не отправляется",
    u"小队中没有其他人开启了 UnrealQuest 的此选项，因此不会发送",
),
"CMD_ANNOUNCE_SHARED_NOTE": (
    u"only a quest another member is known to have is reported; nothing else can be known",
    u"seule une quête qu'un autre membre a vraiment est annoncée ; le reste est inconnaissable",
    u"объявляется только задание, которое точно есть у другого участника",
    u"只播报确知其他队友也接了的任务，其余无法得知",
),
"CMD_ANNOUNCE_COMPLETION_NOTE": (
    u"completed objectives are reported to your group without requiring a shared quest",
    u"les objectifs termines sont annonces au groupe sans exiger une quete commune",
    u"выполненные цели объявляются группе даже без общего задания",
    u"目标完成后会向小队播报，无需队友也接了同一任务",
),
"CMD_ANNOUNCE_NO_ADDON_CHANNEL": (
    u"this client has no SendAddonMessage, so no group member can ever be known to share a quest",
    u"ce client n'a pas SendAddonMessage : impossible de savoir si un membre partage une quête",
    u"у клиента нет SendAddonMessage, поэтому нельзя узнать общие задания",
    u"此客户端没有 SendAddonMessage，无法得知队友是否接了同一任务",
),
"CMD_ANNOUNCE_COUNTS": (
    u"%s lines queued, %s sent, %s refused, %s dropped",
    u"%s lignes en file, %s envoyées, %s refusées, %s abandonnées",
    u"в очереди: %s, отправлено: %s, отклонено: %s, потеряно: %s",
    u"排队 %s 行，已发送 %s，被拒 %s，丢弃 %s",
),
"CMD_ANNOUNCE_LAST": (
    u"last: %s",
    u"dernière : %s",
    u"последняя: %s",
    u"最后一条：%s",
),
"CMD_ANNOUNCE_ON": (
    u"objective progress will be reported in party chat",
    u"la progression des objectifs sera annoncée en chat de groupe",
    u"прогресс целей будет объявляться в чате группы",
    u"目标进度将在小队频道播报",
),
"CMD_ANNOUNCE_OFF": (
    u"objective progress stays out of party chat",
    u"la progression des objectifs reste hors du chat de groupe",
    u"прогресс целей не попадёт в чат группы",
    u"目标进度不会发到小队频道",
),
"CMD_ANNOUNCE_SOLO": (
    u"nothing is sent while you are alone: there is no group channel to write to",
    u"rien n'est envoyé en solo : il n'y a pas de canal de groupe",
    u"в одиночку ничего не отправляется: нет канала группы",
    u"单人时不会发送：没有小队频道",
),
"CMD_ANNOUNCE_UNAVAILABLE": (
    u"this client has no SendChatMessage, so nothing can be posted at all",
    u"ce client n'a pas SendChatMessage : rien ne peut être publié",
    u"у этого клиента нет SendChatMessage, отправить нечего",
    u"此客户端没有 SendChatMessage，无法发送",
),
"CMD_ANNOUNCE_BLOCKED": (
    u"the client refused every attempt, so sending is stopped for this session",
    u"le client a tout refusé : l'envoi est arrêté pour cette session",
    u"клиент отклонил все попытки: отправка остановлена на эту сессию",
    u"客户端拒绝了所有尝试，本次登录已停止发送",
),
"CMD_ANNOUNCE_PROTECTED_NOTE": (
    u"the client's API reference marks SendChatMessage protected; only a real send settles it",
    u"la référence du client marque SendChatMessage protégée ; seul un envoi réel tranche",
    u"в справочнике клиента SendChatMessage помечена как защищённая; проверить может только реальная отправка",
    u"客户端文档将 SendChatMessage 标为受保护，只有实际发送才能确认",
),
"CMD_RARE_TITLE": (
    u"rare / elite proximity alert:",
    u"alerte de proximité rare / élite :",
    u"оповещение о редких и элитных:",
    u"稀有 / 精英接近提醒：",
),
"CMD_RARE_SETTING": (
    u"alert: %s",
    u"alerte : %s",
    u"оповещение: %s",
    u"提醒：%s",
),
"CMD_RARE_RANGE": (
    u"range: %s yards, card stays %s seconds",
    u"portée : %s mètres, carte affichée %s secondes",
    u"дальность: %s м, карточка держится %s сек",
    u"距离：%s 码，提示停留 %s 秒",
),
"CMD_RARE_SOUND": (
    u"sound kit: %s (played %s times)",
    u"kit sonore : %s (joué %s fois)",
    u"звук: %s (воспроизведён %s раз)",
    u"音效：%s（已播放 %s 次）",
),
"CMD_RARE_STATE": (
    u"state: %s, area: %s",
    u"état : %s, zone : %s",
    u"состояние: %s, зона: %s",
    u"状态：%s，区域：%s",
),
"CMD_RARE_INDEX": (
    u"index: %s, %s ranked creatures, %s in this zone",
    u"index : %s, %s créatures classées, %s dans cette zone",
    u"индекс: %s, существ с рангом: %s, в этой зоне: %s",
    u"索引：%s，有等级的生物 %s 个，本区域 %s 个",
),
"CMD_RARE_COUNTS": (
    u"%s alerts over %s scans",
    u"%s alertes sur %s analyses",
    u"оповещений: %s за %s проверок",
    u"%s 次提醒，共 %s 次扫描",
),
"CMD_RARE_LAST": (
    u"last: %s (%s) at %s yards",
    u"dernier : %s (%s) à %s mètres",
    u"последний: %s (%s) на %s м",
    u"最近：%s（%s），%s 码",
),
"CMD_RARE_ON": (
    u"rare / elite alert on",
    u"alerte rare / élite activée",
    u"оповещение о редких включено",
    u"稀有 / 精英提醒已开启",
),
"CMD_RARE_OFF": (
    u"rare / elite alert off",
    u"alerte rare / élite désactivée",
    u"оповещение о редких выключено",
    u"稀有 / 精英提醒已关闭",
),
"CMD_RARE_RANGE_SET": (
    u"alert range set to %s yards",
    u"portée de l'alerte réglée à %s mètres",
    u"дальность оповещения: %s м",
    u"提醒距离设为 %s 码",
),
"CMD_RARE_RANGE_USAGE": (
    u"usage: /uq rare range <20-500>",
    u"utilisation : /uq rare range <20-500>",
    u"использование: /uq rare range <20-500>",
    u"用法：/uq rare range <20-500>",
),
"CMD_RARE_POSITION_RESET": (
    u"alert card moved back to its default position",
    u"carte d'alerte replacée à sa position par défaut",
    u"карточка оповещения возвращена на исходное место",
    u"提醒卡片已移回默认位置",
),
"CMD_RARE_SOUND_SET": (
    u"sound kit set to %s -- it just played, or the client does not know it",
    u"kit sonore réglé sur %s — il vient de jouer, ou le client l'ignore",
    u"звук: %s — он только что прозвучал, либо клиент его не знает",
    u"音效设为 %s — 刚刚已播放，或客户端不认识它",
),
"CMD_RARE_SOUND_USAGE": (
    u"usage: /uq rare sound <SoundEntries kit name>",
    u"utilisation : /uq rare sound <nom de kit SoundEntries>",
    u"использование: /uq rare sound <имя набора SoundEntries>",
    u"用法：/uq rare sound <SoundEntries 音效名>",
),
"CMD_RARE_SOUND_HINT": (
    u"an unknown kit name is silent, not an error -- if you heard nothing, try another",
    u"un nom de kit inconnu est silencieux, pas une erreur — si vous n'avez rien entendu, essayez-en un autre",
    u"неизвестное имя просто молчит, это не ошибка — если ничего не слышно, попробуйте другое",
    u"未知音效名只是静音，并非错误 — 若没有声音，请换一个",
),
"CMD_RARE_SOUND_MISSING": (
    u"this client has no PlaySound, so the alert is silent",
    u"ce client n'a pas PlaySound, l'alerte est donc muette",
    u"у этого клиента нет PlaySound, поэтому оповещение беззвучное",
    u"此客户端没有 PlaySound，提醒将无声",
),
"CMD_RARE_TEST_OK": (
    u"test card raised on %s",
    u"carte de test affichée pour %s",
    u"тестовая карточка для %s",
    u"已对 %s 弹出测试提示",
),
"CMD_RARE_TEST_FAILED": (
    u"nothing to raise a card on: %s",
    u"rien à afficher : %s",
    u"нечего показать: %s",
    u"无可提示的目标：%s",
),
"CMD_RARE_PROXIMITY_NOTE": (
    u"this is proximity to a recorded spawn, not a live sighting -- see docs/RARE-ALERT.md",
    u"c'est la proximité d'une apparition connue, pas une observation en direct — voir docs/RARE-ALERT.md",
    u"это близость к известной точке появления, а не живое обнаружение — см. docs/RARE-ALERT.md",
    u"这是与已知刷新点的距离，而非实时发现 — 参见 docs/RARE-ALERT.md",
),
}
