# -*- coding: utf-8 -*-
# /uq help and the generic command chrome. key -> (en, fr, ru, cn)

STRINGS = {

"CMD_HELP_TITLE": (
    "v%s commands:", "v%s commandes :", "v%s команды:", "v%s 命令："),

"CMD_HELP_CONFIG": (
    "/uq config    open the options window",
    "/uq config    ouvrir la fenêtre d'options",
    "/uq config    открыть окно настроек",
    "/uq config    打开选项窗口",
),
"CMD_HELP_CONFIG_BUTTON": (
    "/uq config button on|off      the settings button beside the minimap",
    "/uq config button on|off      le bouton de réglages à côté de la mini-carte",
    "/uq config button on|off      кнопка настроек рядом с миникартой",
    "/uq config button on|off      小地图旁的设置按钮",
),
"CMD_HELP_STATUS": (
    "/uq status    what this build established about the client",
    "/uq status    ce que cette version a établi sur le client",
    "/uq status    что эта сборка установила о клиенте",
    "/uq status    此版本对客户端的确认结果",
),
"CMD_HELP_QUESTS": (
    "/uq quests    the current quest log model",
    "/uq quests    le modèle actuel du journal de quêtes",
    "/uq quests    текущая модель журнала заданий",
    "/uq quests    当前任务日志模型",
),
"CMD_HELP_EVENTS": (
    "/uq events    which quest events this client accepted and fired",
    "/uq events    quels événements de quête ce client a acceptés et déclenchés",
    "/uq events    какие события заданий клиент принял и вызвал",
    "/uq events    此客户端接受并触发了哪些任务事件",
),
"CMD_HELP_MAP": (
    "/uq map       current map identity and world-map pin status",
    "/uq map       identité de la carte actuelle et état des repères",
    "/uq map       текущая карта и состояние меток на карте мира",
    "/uq map       当前地图标识与世界地图标记状态",
),
"CMD_HELP_MAP_STYLE": (
    "/uq map dots|areas  draw quest objectives as dots or as shaded areas",
    "/uq map dots|areas  dessiner les objectifs en points ou en zones ombrées",
    "/uq map dots|areas  рисовать цели точками или закрашенными областями",
    "/uq map dots|areas  以圆点或阴影区域绘制任务目标",
),
"CMD_HELP_MAP_VENDORS": (
    "/uq map vendors on|off  show where quest items you have to buy are sold",
    "/uq map vendors on|off  montrer où s'achètent les objets de quête à acheter",
    "/uq map vendors on|off  показывать, где продаются предметы заданий",
    "/uq map vendors on|off  显示需要购买的任务物品在何处出售",
),
"CMD_HELP_MINIMAP": (
    "/uq minimap   quest pins around the player on the minimap",
    "/uq minimap   repères de quête autour du joueur sur la mini-carte",
    "/uq minimap   метки заданий вокруг игрока на миникарте",
    "/uq minimap   小地图上玩家周围的任务标记",
),
"CMD_HELP_MINIMAP_ONOFF": (
    "/uq minimap on|off            draw them, or stop",
    "/uq minimap on|off            les dessiner, ou arrêter",
    "/uq minimap on|off            рисовать их или прекратить",
    "/uq minimap on|off            绘制或停止绘制",
),
"CMD_HELP_MINIMAP_SPAN": (
    "/uq minimap span <yards>       dial in the scale for this zoom step",
    "/uq minimap span <yards>       ajuster l'échelle pour ce niveau de zoom",
    "/uq minimap span <yards>       подстроить масштаб для этого шага зума",
    "/uq minimap span <yards>       为该缩放级别微调比例",
),
"CMD_HELP_MINIMAP_INDOORS": (
    "/uq minimap indoors on|off    withhold markers indoors, or draw them anyway",
    "/uq minimap indoors on|off    masquer les repères en intérieur, ou les dessiner quand même",
    "/uq minimap indoors on|off    скрывать метки в помещении или рисовать их всё равно",
    "/uq minimap indoors on|off    在室内隐藏标记，或仍然绘制",
),
"CMD_HELP_DB": (
    "/uq db        static quest database state",
    "/uq db        état de la base de données de quêtes",
    "/uq db        состояние статической базы заданий",
    "/uq db        静态任务数据库状态",
),
"CMD_HELP_TOOLTIP": (
    "/uq tooltip   entity-tooltip objective diagnostics",
    "/uq tooltip   diagnostics des objectifs dans les infobulles",
    "/uq tooltip   диагностика целей в подсказках существ",
    "/uq tooltip   实体提示中的目标诊断",
),
"CMD_HELP_TRACKER": (
    "/uq tracker   the movable quest tracker window",
    "/uq tracker   la fenêtre de suivi de quêtes déplaçable",
    "/uq tracker   перемещаемое окно трекера заданий",
    "/uq tracker   可移动的任务追踪窗口",
),
"CMD_HELP_TRACKER_ONOFF": (
    "/uq tracker on|off|toggle     show or hide it",
    "/uq tracker on|off|toggle     l'afficher ou la masquer",
    "/uq tracker on|off|toggle     показать или скрыть его",
    "/uq tracker on|off|toggle     显示或隐藏",
),
"CMD_HELP_TRACKER_RESET": (
    "/uq tracker reset             move it back to its default position",
    "/uq tracker reset             la remettre à sa position par défaut",
    "/uq tracker reset             вернуть его в положение по умолчанию",
    "/uq tracker reset             移回默认位置",
),
"CMD_HELP_TRACKER_OBJECTIVES": (
    "/uq tracker objectives all|tracked|none",
    "/uq tracker objectives all|tracked|none",
    "/uq tracker objectives all|tracked|none",
    "/uq tracker objectives all|tracked|none",
),
"CMD_HELP_TRACKER_ZONES": (
    "/uq tracker zones             group by zone, or do not",
    "/uq tracker zones             grouper par zone, ou non",
    "/uq tracker zones             группировать по зонам или нет",
    "/uq tracker zones             按区域分组，或不分组",
),
"CMD_HELP_TRACKER_WIDTH": (
    "/uq tracker width <110-600>   how wide the window is",
    "/uq tracker width <110-600>   largeur de la fenêtre",
    "/uq tracker width <110-600>   ширина окна",
    "/uq tracker width <110-600>   窗口宽度",
),
"CMD_HELP_TRACKER_HEIGHT": (
    "/uq tracker height <60-900>   max height in pixels, 0 for no limit",
    "/uq tracker height <60-900>   hauteur max en pixels, 0 pour aucune limite",
    "/uq tracker height <60-900>   макс. высота в пикселях, 0 -- без ограничения",
    "/uq tracker height <60-900>   最大高度（像素），0 表示不限",
),
"CMD_HELP_TRACKER_UNFOLD": (
    "/uq tracker unfold            reopen every folded quest and zone",
    "/uq tracker unfold            rouvrir toutes les quêtes et zones repliées",
    "/uq tracker unfold            раскрыть все свёрнутые задания и зоны",
    "/uq tracker unfold            展开所有折叠的任务和区域",
),
"CMD_HELP_TRACKER_UNHIDEALL": (
    "/uq tracker unhideall         bring back every quest untracked out of the tracker",
    "/uq tracker unhideall         ramener toutes les quêtes retirées du suivi",
    "/uq tracker unhideall         вернуть все задания, убранные из трекера",
    "/uq tracker unhideall         恢复所有被移出追踪器的任务",
),
"CMD_HELP_TRACKER_NATIVE": (
    "/uq tracker native            hide or restore the client's own watch panel",
    "/uq tracker native            masquer ou restaurer le panneau de suivi du client",
    "/uq tracker native            скрыть или вернуть родную панель слежения клиента",
    "/uq tracker native            隐藏或恢复客户端自带的追踪面板",
),

"CMD_HELP_MAIN_SET": (
    "/uq main <index or title>     follow a quest with the HUD waypoint",
    "/uq main <index ou titre>     suivre une quête avec le repère ATH",
    "/uq main <индекс или название>  следовать за заданием с маркером HUD",
    "/uq main <序号或标题>          用 HUD 路径点跟随一个任务",
),
"CMD_HELP_MAIN_REPORT": (
    "/uq main                      report the followed quest",
    "/uq main                      indiquer la quête suivie",
    "/uq main                      сообщить, за каким заданием следуем",
    "/uq main                      报告当前跟随的任务",
),
"CMD_HELP_MAIN_CLEAR": (
    "/uq main clear                stop following",
    "/uq main clear                arrêter de suivre",
    "/uq main clear                прекратить следование",
    "/uq main clear                停止跟随",
),
"CMD_HELP_WAYPOINT": (
    "/uq waypoint  HUD waypoint marker diagnostics",
    "/uq waypoint  diagnostics du repère ATH",
    "/uq waypoint  диагностика маркера HUD",
    "/uq waypoint  HUD 路径点标记诊断",
),
"CMD_HELP_MAIN_DISABLED": (
    "/uq main, /uq waypoint   disabled in this build",
    "/uq main, /uq waypoint   désactivés dans cette version",
    "/uq main, /uq waypoint   отключены в этой сборке",
    "/uq main, /uq waypoint   在此版本中已停用",
),

"CMD_HELP_TRACK": (
    "/uq track <index or title>    track a quest",
    "/uq track <index ou titre>    suivre une quête",
    "/uq track <индекс или название>  отслеживать задание",
    "/uq track <序号或标题>         追踪一个任务",
),
"CMD_HELP_UNTRACK": (
    "/uq untrack <index or title>  stop tracking a quest",
    "/uq untrack <index ou titre>  ne plus suivre une quête",
    "/uq untrack <индекс или название>  прекратить отслеживание",
    "/uq untrack <序号或标题>       停止追踪一个任务",
),
"CMD_HELP_TOGGLE": (
    "/uq toggle <index or title>   toggle quest tracking",
    "/uq toggle <index ou titre>   basculer le suivi d'une quête",
    "/uq toggle <индекс или название>  переключить отслеживание",
    "/uq toggle <序号或标题>        切换任务追踪",
),
"CMD_HELP_HIDE": (
    "/uq hide <index or title>     hide a quest's pins from the world map",
    "/uq hide <index ou titre>     masquer les repères d'une quête sur la carte",
    "/uq hide <индекс или название>  скрыть метки задания с карты мира",
    "/uq hide <序号或标题>          在世界地图上隐藏某任务的标记",
),
"CMD_HELP_UNHIDE": (
    "/uq unhide <index or title>   restore a quest's map pins",
    "/uq unhide <index ou titre>   restaurer les repères d'une quête",
    "/uq unhide <индекс или название>  вернуть метки задания на карту",
    "/uq unhide <序号或标题>        恢复某任务的地图标记",
),
"CMD_HELP_HIDDEN": (
    "/uq hidden                    list quests hidden from the map",
    "/uq hidden                    lister les quêtes masquées de la carte",
    "/uq hidden                    список заданий, скрытых с карты",
    "/uq hidden                    列出从地图隐藏的任务",
),
"CMD_HELP_RESETMARKED": (
    "/uq resetmarked               undo every shift/Ctrl-click 'mark done' on the map",
    "/uq resetmarked               annuler chaque « terminée » posée par Maj/Ctrl+clic",
    "/uq resetmarked               отменить все отметки «выполнено» по Shift/Ctrl+клику",
    "/uq resetmarked               撤销地图上所有 Shift/Ctrl+点击的“已完成”标记",
),
"CMD_HELP_RESETMARKED_ALL": (
    "/uq resetmarked all           also undo marks made before that tracking existed",
    "/uq resetmarked all           annuler aussi les marques posées avant ce suivi",
    "/uq resetmarked all           отменить и отметки, сделанные до появления учёта",
    "/uq resetmarked all           同时撤销该记录功能出现前所做的标记",
),
"CMD_HELP_PFQUEST": (
    "/uq pfquest                   report what pfQuest's saved history holds",
    "/uq pfquest                   indiquer ce que contient l'historique de pfQuest",
    "/uq pfquest                   сообщить, что содержит история pfQuest",
    "/uq pfquest                   报告 pfQuest 的历史记录内容",
),
"CMD_HELP_PFQUEST_IMPORT": (
    "/uq pfquest import            import it -- enables pfQuest for one reload if needed",
    "/uq pfquest import            l'importer -- active pfQuest pour un rechargement si besoin",
    "/uq pfquest import            импортировать -- при необходимости включит pfQuest на одну перезагрузку",
    "/uq pfquest import            导入 -- 必要时为一次重载启用 pfQuest",
),
"CMD_HELP_PFQUEST_UNDO": (
    "/uq pfquest undo              take back everything a previous import added",
    "/uq pfquest undo              annuler tout ce qu'un import précédent a ajouté",
    "/uq pfquest undo              отменить всё, что добавил предыдущий импорт",
    "/uq pfquest undo              撤回之前导入所添加的一切",
),
"CMD_HELP_MARKS": (
    "/uq marks                 quest marks over creatures in the world",
    "/uq marks                 marques de quête sur les créatures du monde",
    "/uq marks                 метки заданий над существами в мире",
    "/uq marks                 世界中生物头顶的任务标记",
),
"CMD_HELP_MARKS_ONOFF": (
    "/uq marks on|off          mark quest creatures with a raid target icon",
    "/uq marks on|off          marquer les créatures de quête avec une icône de raid",
    "/uq marks on|off          помечать существ заданий рейдовой меткой",
    "/uq marks on|off          用团队目标图标标记任务生物",
),
"CMD_HELP_MARKS_ICON": (
    "/uq marks icon <1-8>      which mark: 1 star .. 8 skull",
    "/uq marks icon <1-8>      quelle marque : 1 étoile .. 8 crâne",
    "/uq marks icon <1-8>      какая метка: 1 звезда .. 8 череп",
    "/uq marks icon <1-8>      使用哪种标记：1 星星 .. 8 骷髅",
),
"CMD_HELP_MARKS_GROUP": (
    "/uq marks group on|off    also mark while in a party or raid",
    "/uq marks group on|off    marquer aussi en groupe ou en raid",
    "/uq marks group on|off    помечать также в группе или рейде",
    "/uq marks group on|off    在小队或团队中也进行标记",
),
"CMD_HELP_WORLDSCAN": (
    "/uq worldscan             inventory WorldFrame's children (nameplate hunt)",
    "/uq worldscan             inventorier les enfants de WorldFrame (chasse aux barres de nom)",
    "/uq worldscan             перечислить дочерние объекты WorldFrame (поиск индикаторов)",
    "/uq worldscan             清点 WorldFrame 的子对象（查找姓名板）",
),
"CMD_HELP_WORLDSCAN_CHILD": (
    "/uq worldscan <n>         one child in full: every region and child",
    "/uq worldscan <n>         un enfant en détail : chaque région et enfant",
    "/uq worldscan <n>         один дочерний объект целиком: все области и дети",
    "/uq worldscan <n>         完整显示某个子对象：所有区域与子级",
),
"CMD_HELP_DEBUG": (
    "/uq debug     toggle debug output",
    "/uq debug     activer/désactiver la sortie de débogage",
    "/uq debug     включить/выключить отладочный вывод",
    "/uq debug     切换调试输出",
),

# --- generic command chrome --------------------------------------------------
"CMD_UNKNOWN": (
    "unknown command: %s", "commande inconnue : %s",
    "неизвестная команда: %s", "未知命令：%s"),
"CMD_DEBUG_ENABLED": (
    "debug output enabled", "sortie de débogage activée",
    "отладочный вывод включён", "调试输出已启用"),
"CMD_DEBUG_DISABLED": (
    "debug output disabled", "sortie de débogage désactivée",
    "отладочный вывод отключён", "调试输出已禁用"),
"CMD_STATE_DISABLED": ("disabled", "désactivé", "отключено", "已停用"),

"CMD_MODULE_MISSING_QUEST_STATE": (
    "quest state module is not loaded",
    "le module d'état des quêtes n'est pas chargé",
    "модуль состояния заданий не загружен",
    "任务状态模块未加载",
),
"CMD_MODULE_MISSING_EVENTS": (
    "event module is not loaded", "le module d'événements n'est pas chargé",
    "модуль событий не загружен", "事件模块未加载"),
"CMD_MODULE_MISSING_MAP": (
    "map module is not loaded", "le module de carte n'est pas chargé",
    "модуль карты не загружен", "地图模块未加载"),
"CMD_MODULE_MISSING_CONFIG": (
    "config module is not loaded", "le module de configuration n'est pas chargé",
    "модуль настроек не загружен", "配置模块未加载"),
"CMD_MODULE_MISSING_MINIMAP": (
    "minimap pin module is not loaded",
    "le module de repères de mini-carte n'est pas chargé",
    "модуль меток миникарты не загружен", "小地图标记模块未加载"),
"CMD_MODULE_MISSING_DATABASE": (
    "database module is not loaded", "le module de base de données n'est pas chargé",
    "модуль базы данных не загружен", "数据库模块未加载"),
"CMD_MODULE_MISSING_TOOLTIP": (
    "entity tooltip module is not loaded",
    "le module d'infobulle d'entité n'est pas chargé",
    "модуль подсказок существ не загружен", "实体提示模块未加载"),
"CMD_MODULE_MISSING_MARKS": (
    "quest mark module is not loaded",
    "le module de marques de quête n'est pas chargé",
    "модуль меток заданий не загружен", "任务标记模块未加载"),
"CMD_MODULE_MISSING_WORLDSCAN": (
    "world scan module is not loaded", "le module d'analyse du monde n'est pas chargé",
    "модуль сканирования мира не загружен", "世界扫描模块未加载"),
"CMD_MODULE_MISSING_TRACKER": (
    "tracker module is not loaded", "le module de suivi n'est pas chargé",
    "модуль отслеживания не загружен", "追踪模块未加载"),
"CMD_MODULE_MISSING_TRACKER_FRAME": (
    "the tracker module is not loaded", "le module de la fenêtre de suivi n'est pas chargé",
    "модуль окна трекера не загружен", "追踪器模块未加载"),
"CMD_MODULE_MISSING_REQUIRED": (
    "required modules are not loaded", "les modules requis ne sont pas chargés",
    "необходимые модули не загружены", "所需模块未加载"),
"CMD_MODULE_MISSING_HISTORY": (
    "quest history module is not loaded",
    "le module d'historique des quêtes n'est pas chargé",
    "модуль истории заданий не загружен", "任务历史模块未加载"),
"CMD_MODULE_MISSING_PFQUEST": (
    "the pfQuest import module is not loaded",
    "le module d'import pfQuest n'est pas chargé",
    "модуль импорта pfQuest не загружен", "pfQuest 导入模块未加载"),
"CMD_MODULE_MISSING_MAINQUEST": (
    "the main quest module is unavailable",
    "le module de quête principale est indisponible",
    "модуль главного задания недоступен", "主线任务模块不可用"),
"CMD_MODULE_MISSING_WAYPOINT": (
    "the waypoint module is unavailable", "le module de repère est indisponible",
    "модуль маркера недоступен", "路径点模块不可用"),
"CMD_MODULE_MISSING_SETTINGS": (
    "the settings module is not loaded", "le module de réglages n'est pas chargé",
    "модуль настроек не загружен", "设置模块未加载"),

"CMD_HELP_RARE": (
    u"/uq rare      the rare / elite proximity alert",
    u"/uq rare      l'alerte de proximité rare / élite",
    u"/uq rare      оповещение о редких и элитных",
    u"/uq rare      稀有 / 精英接近提醒",
),
"CMD_HELP_RARE_ONOFF": (
    u"/uq rare on|off               turn the alert on or off",
    u"/uq rare on|off               activer ou désactiver l'alerte",
    u"/uq rare on|off               включить или выключить оповещение",
    u"/uq rare on|off               开启或关闭提醒",
),
"CMD_HELP_RARE_RANGE": (
    u"/uq rare range <yards>        how near counts as near",
    u"/uq rare range <mètres>       à quelle distance l'alerte se déclenche",
    u"/uq rare range <метры>        на каком расстоянии срабатывать",
    u"/uq rare range <码>          多近算靠近",
),
"CMD_HELP_RARE_SOUND": (
    u"/uq rare sound <kit>          play and keep a SoundEntries kit",
    u"/uq rare sound <kit>          jouer et garder un kit SoundEntries",
    u"/uq rare sound <kit>          проиграть и сохранить набор SoundEntries",
    u"/uq rare sound <kit>          试听并保存 SoundEntries 音效",
),
"CMD_HELP_RARE_TEST": (
    u"/uq rare test                 raise the card on the nearest one",
    u"/uq rare test                 afficher la carte pour le plus proche",
    u"/uq rare test                 показать карточку для ближайшего",
    u"/uq rare test                 对最近的目标弹出提示",
),
}
