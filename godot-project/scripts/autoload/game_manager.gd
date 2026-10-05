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
var settings: Dictionary = {
	"mouse_sensitivity": 0.002,
	"volume": 0.8,
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
	apply_settings()

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
	var f := FileAccess.open(handbook_path, FileAccess.WRITE)
	if f == null:
		# 写失败不丢数据：内存态照常生效，只警告一次（不刷屏）
		if not _save_warned:
			_save_warned = true
			push_warning("手册存档写入失败（保持内存态）：" + handbook_path)
		return
	f.store_string(JSON.stringify(handbook, "\t"))
	f.close()

# ================= 设置（存了就要生效） =================

func get_setting(key: String) -> Variant:
	return settings.get(key, null)

func set_setting(key: String, value: Variant) -> void:
	if not settings.has(key):
		push_warning("未知设置项：" + key)
		return
	settings[key] = value
	apply_settings()
	settings_changed.emit(key, value)

func apply_settings() -> void:
	# 音量 → Master 总线（环境音/杯碟声同受控）
	var vol: float = clampf(float(settings.get("volume", 0.8)), 0.0001, 1.0)
	AudioServer.set_bus_volume_db(0, linear_to_db(vol))
	# mouse_sensitivity 由玩家控制器在 _ready 与 settings_changed 时读取
	# fullscreen 仅存储：显示策略不在本轮操作逻辑范围

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
		game_paused.emit()
	else:
		get_tree().paused = false
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
