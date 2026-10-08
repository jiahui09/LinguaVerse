extends CanvasLayer

## 极简操作提示层（docs/操作逻辑-设计与实施.md §1.2 / §2.2）
## - 底部单行 quicktips：开局浮现，移动/环顾/交谈/手册各"用过一次"后淡出（规则 6：教学不是 HUD）
## - 准星下方 E 提示：射线命中可对话 NPC 时浮现 "E · Parler à Marie"，目标消失即隐
## 借 GTA_SZ city-quicktips.ts 模式（单行常驻、按状态换文案），本项目更简：一次性教学后退场

const TIP_TEXT := "WASD 移动 · 鼠标环顾 · E 交谈 · Tab 手册"

const COLOR_TEXT := Color(1.0, 1.0, 1.0, 0.92)
const COLOR_HINT_BG_ACCENT := Color(1.0, 0.86, 0.55, 0.95)

var _tip_label: Label
var _hint_label: Label
var _crosshair: ColorRect
var _current_npc: Node = null
var _used: Dictionary = {"move": false, "look": false, "interact": false, "handbook": false}
var _tips_faded: bool = false

func _ready():
	layer = 20
	add_to_group("hud_hints")
	_build_ui()

	var ray = get_node_or_null("/root/Main/Player/Camera3D/InteractionRay")
	if ray:
		ray.target_found.connect(_on_target_found)
		ray.target_lost.connect(_on_target_lost)

func _build_ui():
	# 底部单行键位条（全宽居中，不占交互空间）
	_tip_label = Label.new()
	_tip_label.text = TIP_TEXT
	_tip_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tip_label.anchor_left = 0.0
	_tip_label.anchor_right = 1.0
	_tip_label.anchor_top = 1.0
	_tip_label.anchor_bottom = 1.0
	_tip_label.offset_top = -52.0
	_tip_label.offset_bottom = -24.0
	_tip_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_apply_label_style(_tip_label, 17, COLOR_TEXT)
	add_child(_tip_label)

	# 准星下方 E 提示（屏幕中心偏下，居中生长不跳位）
	_hint_label = Label.new()
	_hint_label.text = ""
	_hint_label.visible = false
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_label.anchor_left = 0.5
	_hint_label.anchor_right = 0.5
	_hint_label.anchor_top = 0.5
	_hint_label.anchor_bottom = 0.5
	_hint_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_hint_label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_hint_label.offset_left = -300.0
	_hint_label.offset_right = 300.0
	_hint_label.offset_top = 28.0
	_hint_label.offset_bottom = 56.0
	_hint_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_apply_label_style(_hint_label, 19, COLOR_HINT_BG_ACCENT)
	add_child(_hint_label)

	# 中央准星（P3 批次3：可见准星；无交互高亮——E 提示在其下方独立出现）
	_crosshair = ColorRect.new()
	_crosshair.color = Color(1.0, 1.0, 1.0, 0.9)
	_crosshair.anchor_left = 0.5
	_crosshair.anchor_right = 0.5
	_crosshair.anchor_top = 0.5
	_crosshair.anchor_bottom = 0.5
	_crosshair.offset_left = -2.5
	_crosshair.offset_right = 2.5
	_crosshair.offset_top = -2.5
	_crosshair.offset_bottom = 2.5
	_crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_crosshair)

## 白字 + 深色描边：任何背景下对比度达标（craft-floor：正文对比 ≥4.5:1）
func _apply_label_style(label: Label, font_size: int, color: Color):
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.85))
	label.add_theme_constant_override("outline_size", 6)

# ================= 输入标记（用 _input 而非 _unhandled_input：
# 即使 Tab 被手册消费、E 被对话消费，教学进度照样推进） =================

func _input(event: InputEvent):
	if _tips_faded:
		return
	if event is InputEventMouseMotion:
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED and event.relative.length() > 0.5:
			_used["look"] = true
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_W, KEY_A, KEY_S, KEY_D:
				_used["move"] = true
			KEY_E:
				_used["interact"] = true
			KEY_TAB:
				_used["handbook"] = true
	_check_fade()

func _check_fade():
	if _tips_faded:
		return
	for k in _used:
		if not _used[k]:
			return
	_fade_tips()

func _fade_tips():
	_tips_faded = true
	var tween = create_tween()
	tween.tween_property(_tip_label, "modulate:a", 0.0, 0.8)
	tween.tween_callback(_tip_label.hide)

# ================= E 目标提示 =================

func _on_target_found(npc: Node):
	_current_npc = npc
	_update_hint()

func _on_target_lost():
	_current_npc = null
	_update_hint()

func _process(_delta: float):
	_update_crosshair()
	# 对话中/手册打开时不显示 E 提示（避免与输入框抢注意力）
	if _current_npc != null:
		_update_hint()

## 准星仅在"可自由环顾"态可见：暂停/对话/手册打开即隐（每帧轮询状态，量级 O(1)）
func _update_crosshair():
	var gm = get_node_or_null("/root/GameManager")   # headless -s 惯例：节点路径解析
	var dm = get_tree().get_first_node_in_group("dialog_manager")
	var dialog_active = dm != null and dm.has_method("is_dialog_active") and dm.is_dialog_active()
	var hb = get_tree().get_first_node_in_group("handbook_ui")
	var hb_open = hb != null and hb.visible
	var paused = gm != null and bool(gm.is_game_paused)
	var want: bool = not paused and not dialog_active and not hb_open
	if _crosshair.visible != want:
		_crosshair.visible = want

func _update_hint():
	var dm = get_tree().get_first_node_in_group("dialog_manager")
	var dialog_active = dm != null and dm.has_method("is_dialog_active") and dm.is_dialog_active()
	var hb = get_tree().get_first_node_in_group("handbook_ui")
	var hb_open = hb != null and hb.visible
	var gm = get_node_or_null("/root/GameManager")
	var paused = gm != null and bool(gm.is_game_paused)
	if _current_npc == null or dialog_active or hb_open or paused:
		_hint_label.visible = false
		return
	var npc_name := ""
	if _current_npc.has_method("get_npc_info"):
		npc_name = str(_current_npc.get_npc_info().get("name", ""))
	elif "npc_name" in _current_npc:
		npc_name = str(_current_npc.npc_name)
	_hint_label.text = "E · Parler à " + npc_name
	_hint_label.visible = true

# ================= 测试接口 =================

## 供断言读取状态：{tips_faded, tip_text, hint_visible, hint_text, used, crosshair}
func get_state() -> Dictionary:
	return {
		"tips_faded": _tips_faded,
		"tip_text": _tip_label.text,
		"hint_visible": _hint_label.visible,
		"hint_text": _hint_label.text,
		"used": _used.duplicate(),
		"crosshair": _crosshair.visible,
	}

## 供断言/自动回放直接标记教学进度（等价于真实按过键）
func mark_used(key: String):
	if _used.has(key):
		_used[key] = true
		_check_fade()

func fade_tips_now() -> void:
	# 测试与截图用：直接淡出（不等四键全用过）
	_fade_tips()
