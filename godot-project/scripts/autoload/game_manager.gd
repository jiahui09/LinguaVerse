extends Node

## 全局游戏管理器（Autoload 单例）
## 管理游戏状态、设置、全局事件 + 新居民手册数据
## 手册设计依据：docs/操作逻辑-设计与实施.md §四（世界反馈 + 新居民手册；规则 6 无分数无等级）

signal game_started()
signal game_paused()
signal game_resumed()
signal settings_changed(key: String, value: Variant)
signal handbook_changed(section: String)   # zones / dayparts / npcs / phrases

const HANDBOOK_PATH := "user://handbook.json"
## P3 批次3：设置持久化（与手册同款白名单校验；路径可注入供 headless 测试）
const SETTINGS_PATH := "user://settings.json"
## 咖啡馆内区阈值（与 ambience_controller.CAFE_INTERIOR_X 一致：同一"x>6 即店内"口径）
const CAFE_INTERIOR_X := 6.0
const ZONE_POLL_INTERVAL := 0.4

## 手册只存 id，展示名在 UI 层翻译（数据与展示分离）
const ZONE_LABELS := {
	"cafe": "Café de la rue · 咖啡馆",
	"street_north": "Rue des Rosiers · 北段",
	"street_center": "Rue des Rosiers · 中段",
	"street_south": "Rue des Rosiers · 南段",
}
const DAYPART_LABELS := {
	"dawn": "清晨", "day": "白天", "dusk": "黄昏", "night": "夜晚",
}

var is_game_paused: bool = false
var settings: Dictionary = _default_settings()

## 设置白名单 + 范围钳制（存档坏值回默认不崩溃；键集合 == settings 键集合）
const SETTING_LIMITS := {
	"mouse_sensitivity": [0.0005, 0.02],
	"volume": [0.0, 1.0],
	"fov": [60.0, 100.0],
	"fullscreen": "bool",
}

func _default_settings() -> Dictionary:
	return {
		"mouse_sensitivity": 0.002,
		"volume": 0.8,
		"fov": 75.0,
		"fullscreen": false,
	}

## 新居民手册数据（幂等：同一区域/同一句/同一人重复事件不重复入账）
## zones/dayparts: id -> 首次时间戳；npcs: id -> {name,job,first_seen,meetings}；phrases: [{text,npc,ts}] 去重
var handbook: Dictionary = _default_handbook()

var _zone_poll_accum: float = 999.0   # 首帧立即轮询一次

func _ready():
	# 暂停时也要能收到 ESC 恢复（否则暂停即软锁）
	process_mode = Node.PROCESS_MODE_ALWAYS
	load_handbook()
	load_settings()
	apply_settings()
	# 窗口失焦自动暂停（回焦不自动恢复：看见暂停面板由玩家按 ESC 继续）
	var win := get_window()
	if win != null and not win.focus_exited.is_connected(_on_focus_exited):
		win.focus_exited.connect(_on_focus_exited)

func _process(delta: float):
	_zone_poll_accum += delta
	if _zone_poll_accum >= ZONE_POLL_INTERVAL:
		_zone_poll_accum = 0.0
		_poll_world_state()

## 轮询玩家所在区域与时段 → 手册足迹（规则 1：探索即进度，静默记录）
func _poll_world_state():
	var player = get_tree().get_first_node_in_group("player")
	if player == null:
		return
	var p: Vector3 = player.global_position
	var zone := "street_center"
	if p.x > CAFE_INTERIOR_X:
		zone = "cafe"
	elif p.z > 25.0:
		zone = "street_north"
	elif p.z < -25.0:
		zone = "street_south"
	record_zone(zone)

	var sun = get_node_or_null("/root/Main/Sun")
	if sun and sun.has_method("get_time_of_day"):
		record_daypart(str(sun.get_time_of_day()))

# ================= 手册记录 API（全部幂等） =================

## 进入区域（首见记时间戳；重复进入不重复计，只刷新信号不发）
func record_zone(zone_id: String) -> bool:
	if handbook.zones.has(zone_id):
		return false
	handbook.zones[zone_id] = int(Time.get_unix_time_from_system())
	_save_handbook()
	handbook_changed.emit("zones")
	return true

## 见过某时段（dawn/day/dusk/night）
func record_daypart(daypart: String) -> bool:
	if handbook.dayparts.has(daypart):
		return false
	handbook.dayparts[daypart] = int(Time.get_unix_time_from_system())
	_save_handbook()
	handbook_changed.emit("dayparts")
	return true

## 认识一位邻居（首见 true；此后仅计数 +1）
func record_npc_met(info: Dictionary) -> bool:
	var npc_id := str(info.get("name", "")).strip_edges()
	if npc_id == "":
		return false
	if handbook.npcs.has(npc_id):
		var entry: Dictionary = handbook.npcs[npc_id]
		entry["meetings"] = int(entry.get("meetings", 1)) + 1
		_save_handbook()
		handbook_changed.emit("npcs")
		return false
	handbook.npcs[npc_id] = {
		"name": npc_id,
		"job": str(info.get("job", "")),
		"first_seen": int(Time.get_unix_time_from_system()),
		"meetings": 1,
	}
	_save_handbook()
	handbook_changed.emit("npcs")
	return true

## 记录被世界接住的句子（成功回复即 acknowledge；按小写去重）
func record_phrase(text: String, npc_name: String) -> bool:
	var normalized := text.strip_edges().to_lower()
	if normalized == "":
		return false
	for p in handbook.phrases:
		if str(p.get("text", "")).strip_edges().to_lower() == normalized:
			return false
	handbook.phrases.append({
		"text": text.strip_edges(),
		"npc": npc_name,
		"ts": int(Time.get_unix_time_from_system()),
	})
	_save_handbook()
	handbook_changed.emit("phrases")
	return true

## UI/测试用快照（深拷贝，防外部改内部数据）
func get_handbook_snapshot() -> Dictionary:
	return {
		"zones": handbook.zones.duplicate(),
		"dayparts": handbook.dayparts.duplicate(),
		"npcs": handbook.npcs.duplicate(true),
		"phrases": handbook.phrases.duplicate(true),
	}

# ================= 手册持久化（白名单校验，坏文件回默认不崩溃） =================

## 存档路径（可注入：headless 测试环境 user:// 可能不可写，测试改写到项目内临时文件）
var handbook_path: String = HANDBOOK_PATH
var _save_warned: bool = false

func _default_handbook() -> Dictionary:
	return {"zones": {}, "dayparts": {}, "npcs": {}, "phrases": []}

## 清空手册并重写存档（测试隔离用；正常游玩不提供重置入口——记录不留痕是设计的一部分）
func reset_handbook() -> void:
	handbook = _default_handbook()
	_save_handbook()

func load_handbook() -> void:
	handbook = _default_handbook()
	if not FileAccess.file_exists(handbook_path):
		return
	var f := FileAccess.open(handbook_path, FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		push_warning("手册存档无法解析，已重置为默认（不崩溃）")
		return
	var d: Dictionary = parsed
	# zones / dayparts：String -> 数值时间戳
	for key in ["zones", "dayparts"]:
		var src = d.get(key, {})
		if src is Dictionary:
			for z in src:
				var v = src[z]
				if z is String and (v is float or v is int) and int(v) > 0:
					handbook[key][z] = int(v)
	# npcs：字段白名单
	var src_npcs = d.get("npcs", {})
	if src_npcs is Dictionary:
		for nid in src_npcs:
			var v = src_npcs[nid]
			if nid is String and v is Dictionary and v.get("name") is String:
				handbook.npcs[nid] = {
					"name": str(v.get("name")),
					"job": str(v.get("job", "")),
					"first_seen": int(v.get("first_seen", 0)),
					"meetings": maxi(1, int(v.get("meetings", 1))),
				}
	# phrases：只收有非空 text 的条目
	var src_p = d.get("phrases", [])
	if src_p is Array:
		for p in src_p:
			if p is Dictionary and p.get("text") is String and str(p.get("text")).strip_edges() != "":
				handbook.phrases.append({
					"text": str(p.get("text")),
					"npc": str(p.get("npc", "")),
					"ts": int(p.get("ts", 0)),
				})

func _save_handbook() -> void:
	# user:// 目录可能尚未创建（-s 模式/全新安装），先保证目录在
	if handbook_path.begins_with("user://"):
		var base_dir := ProjectSettings.globalize_path("user://")
		if DirAccess.dir_exists_absolute(base_dir) == false:
			DirAccess.make_dir_recursive_absolute(base_dir)
	# 原子替换：写 .tmp 再 rename 覆盖。进程在写入中途被杀/断电时，
	# 目标文件仍是上一版完整存档（load 手册对坏档"回默认"= 进度清零，
	# 原子替换把这种最坏情况变成"保留上一次进度"）。
	if not _write_json_atomic(handbook_path, JSON.stringify(handbook, "\t")):
		# 写失败不丢数据：内存态照常生效，只警告一次（不刷屏）
		if not _save_warned:
			_save_warned = true
			push_warning("手册存档写入失败（保持内存态）：" + handbook_path)

## 写 JSON 文件：先写同目录 .tmp，再 rename 覆盖目标；rename 不可用时兜底直写。
## 返回是否成功写到目标路径。
func _write_json_atomic(path: String, text: String) -> bool:
	var abs_path := ProjectSettings.globalize_path(path)
	var abs_tmp := ProjectSettings.globalize_path(path + ".tmp")
	var f := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(text)
	f.flush()
	f.close()
	var err := DirAccess.rename_absolute(abs_tmp, abs_path)
	if err != OK and FileAccess.file_exists(abs_path):
		# 部分平台 rename 不覆盖已存在目标：删旧再试一次
		DirAccess.remove_absolute(abs_path)
		err = DirAccess.rename_absolute(abs_tmp, abs_path)
	if err == OK and FileAccess.file_exists(abs_path):
		return true
	# 兜底：rename 不可用（跨设备/权限）→ 直写目标，至少本次数据不丢
	var f2 := FileAccess.open(path, FileAccess.WRITE)
	if f2 == null:
		return false
	f2.store_string(text)
	f2.close()
	return true

# ================= 设置（存了就要生效 + user://settings.json 持久化） =================

## 存档路径（可注入：headless 测试写到项目内临时文件）
var settings_path: String = SETTINGS_PATH
## set_setting(persist=false) 累积的未落盘标记
var _settings_dirty: bool = false

func get_setting(key: String) -> Variant:
	return settings.get(key, null)

func set_setting(key: String, value: Variant, persist: bool = true) -> void:
	if not SETTING_LIMITS.has(key):
		push_warning("未知设置项：" + key)
		return
	var v = _validated_setting(key, value)   # untyped：Variant 返回值不作 := 推断（项目把该告警当错误）
	if v == null:
		push_warning("设置值类型/范围不合法：" + key)
		return
	settings[key] = v
	if persist:
		save_settings()
	else:
		# 连续调整（滑杆拖动）路径：只改内存，由调用方在收口时 flush_settings()。
		# 否则一次拖动会触发几十次整文件重写（同步 IO 抖动）。
		_settings_dirty = true
	apply_settings()
	settings_changed.emit(key, v)

## set_setting(key, value, false) 之后的收口落盘（拖动结束/面板关闭时调用）
func flush_settings() -> void:
	if not _settings_dirty:
		return
	_settings_dirty = false
	save_settings()

## 是否有待落盘的内存态设置（测试/调试可观测）
func settings_dirty() -> bool:
	return _settings_dirty

## 白名单校验：类型不对/越界回钳制（无法钳制则返回 null=拒收）
func _validated_setting(key: String, value: Variant) -> Variant:
	var lim = SETTING_LIMITS.get(key)
	if lim == null:
		return null
	if lim is String:        # "bool" 标记（Array 与 String 用 == 比较是运行时错误，走类型判断）
		return bool(value)
	if not (value is float or value is int):
		return null
	return clampf(float(value), float(lim[0]), float(lim[1]))

## 显示驱动是否支持窗口模式切换（headless/dummy 不支持 → 全屏只存不切，真机验证）
func display_supports_window_mode() -> bool:
	return not ["headless", "dummy"].has(DisplayServer.get_name())

func load_settings() -> void:
	# 先回默认（load 语义=文件即真相；与手册 load_handbook 同款：坏档=回默认不崩溃）
	settings = _default_settings()
	if not FileAccess.file_exists(settings_path):
		return
	var f := FileAccess.open(settings_path, FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		push_warning("设置存档无法解析，已重置为默认（不崩溃）")
		return
	var d: Dictionary = parsed
	for key in d.keys():
		if not SETTING_LIMITS.has(key):
			continue   # 白名单外键丢弃
		var v = _validated_setting(key, d[key])
		if v == null:
			continue   # 坏值回默认
		settings[key] = v

func save_settings() -> void:
	if settings_path.begins_with("user://"):
		var base_dir := ProjectSettings.globalize_path("user://")
		if DirAccess.dir_exists_absolute(base_dir) == false:
			DirAccess.make_dir_recursive_absolute(base_dir)
	var out := {}
	for key in SETTING_LIMITS.keys():
		out[key] = settings.get(key)
	# 与手册同款原子替换（半截 settings.json = 音量/FOV 回默认）
	_settings_dirty = false   # 全量快照已写盘 → 待落盘标记复位
	if not _write_json_atomic(settings_path, JSON.stringify(out, "\t")):
		push_warning("设置存档写入失败（保持内存态）：" + settings_path)

func apply_settings() -> void:
	# 音量 → Master 总线（环境音/杯碟声/脚步同受控）
	var vol: float = clampf(float(settings.get("volume", 0.8)), 0.0001, 1.0)
	AudioServer.set_bus_volume_db(0, linear_to_db(vol))
	# mouse_sensitivity / fov 由玩家控制器在 _ready 与 settings_changed 时读取
	# 全屏真实生效（headless/dummy 显示驱动不支持窗口模式 → 只存不切；真机显示列批次9 验收清单）
	if display_supports_window_mode():
		DisplayServer.window_set_mode(
			DisplayServer.WINDOW_MODE_FULLSCREEN if bool(settings.get("fullscreen", false))
			else DisplayServer.WINDOW_MODE_WINDOWED)

## 窗口失焦 → 自动暂停（显示暂停面板；对话/手册自行处理失焦时不叠加暂停）
func _on_focus_exited() -> void:
	handle_focus_lost()

func handle_focus_lost() -> void:
	if is_game_paused:
		return
	var dm = get_tree().get_first_node_in_group("dialog_manager")
	if dm != null and dm.has_method("is_dialog_active") and dm.is_dialog_active():
		return
	var hb = get_tree().get_first_node_in_group("handbook_ui")
	if hb != null and hb.visible:
		return
	toggle_pause()

func _unhandled_input(event: InputEvent):
	# 全局暂停/恢复（对话中的 ESC 交给 dialog_manager、手册打开时交给手册）
	if event.is_action_pressed("ui_cancel"):
		var hb = get_tree().get_first_node_in_group("handbook_ui")
		if hb != null and hb.visible:
			return
		var dm = get_tree().get_first_node_in_group("dialog_manager")
		if dm != null and dm.has_method("is_dialog_active") and dm.is_dialog_active():
			return
		toggle_pause()

func toggle_pause():
	is_game_paused = not is_game_paused
	if is_game_paused:
		get_tree().paused = true
		# 暂停面板需要操作鼠标（滑条/按钮），恢复时重新捕获
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		game_paused.emit()
	else:
		get_tree().paused = false
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		game_resumed.emit()

## 获取当前世界状态（供对话系统使用）
func get_world_state() -> Dictionary:
	return {
		"time_of_day": _get_time_of_day(),
		"player_position": _get_player_position(),
	}

func _get_time_of_day() -> String:
	var time = Time.get_time_dict_from_system()
	var hour = time.hour
	if hour >= 6 and hour < 8:
		return "dawn"
	elif hour >= 8 and hour < 17:
		return "day"
	elif hour >= 17 and hour < 20:
		return "dusk"
	else:
		return "night"

func _get_player_position() -> Vector3:
	var player = get_tree().get_first_node_in_group("player")
	if player:
		return player.global_position
	return Vector3.ZERO
