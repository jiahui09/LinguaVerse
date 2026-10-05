extends CanvasLayer

## 新居民手册（docs/操作逻辑-设计与实施.md §4.2）
## Tab 开合 · 三分页（足迹/邻里/语录）· 只记录"发生过什么"——没有分数、没有等级（规则 6）
## 数据全部来自 GameManager（幂等、白名单持久化 user://handbook.json），本层只做展示

const TAB_NAMES := ["足迹 Traces", "邻里 Voisins", "语录 Paroles"]

## 配色取自世界（纸页感暖色压深底）：正文对比 ≥4.5:1（craft-floor）
const COLOR_BG := Color(0.10, 0.095, 0.085, 0.985)
const COLOR_BORDER := Color(0.72, 0.60, 0.40, 0.55)
const COLOR_PAPER := Color(0.95, 0.91, 0.83, 1.0)
const COLOR_DIM := Color(0.74, 0.70, 0.63, 1.0)
const COLOR_ACCENT := Color(0.96, 0.80, 0.45, 1.0)
const COLOR_TAB_IDLE := Color(0.62, 0.58, 0.52, 1.0)

var _current_tab: int = 0
var _root: Control
var _content: RichTextLabel
var _tab_buttons: Array = []
var _title_label: Label
var _gm: Node = null   # GameManager 节点解析（-s headless 模式不注册全局标识）

func _ready():
	layer = 30
	add_to_group("handbook_ui")
	visible = false
	_build_ui()
	_gm = get_node_or_null("/root/GameManager")
	if _gm:
		_gm.handbook_changed.connect(_on_handbook_changed)

func _on_handbook_changed(_section: String):
	if visible:
		_refresh()

# ================= 输入 =================

func _unhandled_input(event: InputEvent):
	if event.is_action_pressed("handbook"):
		# 对话中不开手册（决策 9：输入框是对话的主场）——不消费该键
		var dm = get_tree().get_first_node_in_group("dialog_manager")
		if dm != null and dm.has_method("is_dialog_active") and dm.is_dialog_active():
			return
		toggle()
		get_viewport().set_input_as_handled()
	elif visible and event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()

func toggle():
	if visible:
		close()
	else:
		open()

func open():
	_refresh()
	visible = true
	_set_player_blocked(true)
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

func close():
	visible = false
	_set_player_blocked(false)
	# 手册关闭恢复捕获（暂停状态下不抢鼠标，交给暂停逻辑）
	if _gm != null and not _gm.is_game_paused:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _set_player_blocked(blocked: bool):
	var player = get_tree().get_first_node_in_group("player")
	if player != null and "ui_blocked" in player:
		player.ui_blocked = blocked

# ================= UI 构建（程序化，避免手写 tscn 布局漂移） =================

func _build_ui():
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	# 压暗底（承接全屏，点击不穿透）
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.5)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(dim)

	# 中央手册面板（单层 elevation：1px 暖边框，无阴影——craft-floor 不叠双系统）
	var panel := PanelContainer.new()
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.anchor_top = 0.5
	panel.anchor_bottom = 0.5
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	panel.offset_left = -480.0
	panel.offset_right = 480.0
	panel.offset_top = -300.0
	panel.offset_bottom = 300.0
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var sb := StyleBoxFlat.new()
	sb.bg_color = COLOR_BG
	sb.border_color = COLOR_BORDER
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(12)
	sb.content_margin_left = 32.0
	sb.content_margin_right = 32.0
	sb.content_margin_top = 26.0
	sb.content_margin_bottom = 22.0
	panel.add_theme_stylebox_override("panel", sb)
	_root.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 16)
	panel.add_child(vbox)

	# 页眉
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	vbox.add_child(header)
	_title_label = Label.new()
	_title_label.text = "Carnet du nouveau voisin"
	_style_label(_title_label, 23, COLOR_PAPER)
	header.add_child(_title_label)
	var title_zh := Label.new()
	title_zh.text = "新居民手册"
	_style_label(title_zh, 14, COLOR_DIM)
	title_zh.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	title_zh.add_theme_constant_override("bottom_margin", 4)
	header.add_child(title_zh)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	var close_hint := Label.new()
	close_hint.text = "Tab 关闭"
	_style_label(close_hint, 13, COLOR_DIM)
	close_hint.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	header.add_child(close_hint)

	# 分页按钮
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 8)
	vbox.add_child(tabs)
	for i in TAB_NAMES.size():
		var btn := Button.new()
		btn.text = TAB_NAMES[i]
		btn.toggle_mode = true
		btn.pressed.connect(_on_tab_pressed.bind(i))
		_style_tab_button(btn, false)
		tabs.add_child(btn)
		_tab_buttons.append(btn)

	# 内容区
	_content = RichTextLabel.new()
	_content.bbcode_enabled = true
	_content.scroll_following = true
	_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content.add_theme_font_size_override("normal_font_size", 17)
	_content.add_theme_color_override("default_color", COLOR_PAPER)
	_content.add_theme_constant_override("line_separation", 6)
	vbox.add_child(_content)

	# 页脚：把"没有分数"写在脸上（规则 6）
	var footer := Label.new()
	footer.text = "这里只记录发生过的事——没有分数，没有等级，也没有人给你打分。"
	_style_label(footer, 13, COLOR_DIM)
	vbox.add_child(footer)

func _style_label(label: Label, font_size: int, color: Color):
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)

func _style_tab_button(btn: Button, selected: bool):
	var sb := StyleBoxFlat.new()
	if selected:
		sb.bg_color = Color(1, 1, 1, 0.07)
		sb.border_color = COLOR_ACCENT
		sb.border_width_bottom = 2   # 选中态用 2px 下划线（属性赋值；无逐边 setter）
	else:
		sb.bg_color = Color(0, 0, 0, 0)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 14.0
	sb.content_margin_right = 14.0
	sb.content_margin_top = 7.0
	sb.content_margin_bottom = 7.0
	btn.add_theme_stylebox_override("normal", sb)
	btn.add_theme_stylebox_override("hover", sb)
	btn.add_theme_stylebox_override("pressed", sb)
	btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	btn.add_theme_color_override("font_color", COLOR_ACCENT if selected else COLOR_TAB_IDLE)
	btn.add_theme_color_override("font_hover_color", COLOR_PAPER)
	btn.add_theme_color_override("font_pressed_color", COLOR_ACCENT)
	btn.add_theme_font_size_override("font_size", 16)

func _on_tab_pressed(index: int):
	_current_tab = index
	_refresh()

# ================= 内容渲染 =================

func _refresh():
	for i in _tab_buttons.size():
		var sel := i == _current_tab
		_tab_buttons[i].set_pressed_no_signal(sel)
		_style_tab_button(_tab_buttons[i], sel)
	var snap: Dictionary = _gm.get_handbook_snapshot() if _gm else {"zones": {}, "dayparts": {}, "npcs": {}, "phrases": []}
	match _current_tab:
		0: _content.text = _render_traces(snap)
		1: _content.text = _render_voisins(snap)
		2: _content.text = _render_paroles(snap)

func _render_traces(snap: Dictionary) -> String:
	var zones: Dictionary = snap.get("zones", {})
	var dayparts: Dictionary = snap.get("dayparts", {})
	if zones.is_empty() and dayparts.is_empty():
		return "[color=#9a9287]还没有足迹——推门出去走走吧。\n街道会自己向你展开。[/color]"
	var out := "[b]你走过的街[/b]\n\n"
	var order := ["street_north", "street_center", "street_south", "cafe"]
	for zid in order:
		if not zones.has(zid):
			continue
		var label: String = str(_gm.ZONE_LABELS.get(zid, zid)) if _gm else zid
		out += "· [b]%s[/b] —— 首次踏足 %s\n" % [label, _fmt_ts(zones[zid])]
	if not dayparts.is_empty():
		var parts: Array = []
		for key in ["dawn", "day", "dusk", "night"]:
			if dayparts.has(key):
				parts.append(_gm.DAYPART_LABELS.get(key, key) if _gm else key)
		out += "\n[i]你在这些时段出过门：%s[/i]" % "、".join(parts)
	return out

func _render_voisins(snap: Dictionary) -> String:
	var npcs: Dictionary = snap.get("npcs", {})
	if npcs.is_empty():
		return "[color=#9a9287]还没有认识的人——走近街上的邻居，开口打个招呼。\n哪怕只是 Bonjour。[/color]"
	var out := "[b]你认识的邻居[/b]\n\n"
	for nid in npcs:
		var n: Dictionary = npcs[nid]
		var job := str(n.get("job", ""))
		var job_part := (" · " + job) if job != "" else ""
		out += "[b]%s[/b]%s\n   见过 %d 次 · 第一次 %s\n" % [
			_sanitize(str(n.get("name", nid))),
			_sanitize(job_part),
			int(n.get("meetings", 1)),
			_fmt_ts(n.get("first_seen", 0)),
		]
	return out

func _render_paroles(snap: Dictionary) -> String:
	var phrases: Array = snap.get("phrases", [])
	if phrases.is_empty():
		return "[color=#9a9287]还没有被听懂的话——去咖啡馆试试说一句：\n[i]un café, s'il vous plaît[/i][/color]"
	var out := "[b]被听懂的句子[/b]\n\n"
	for i in range(phrases.size() - 1, -1, -1):
		var p: Dictionary = phrases[i]
		out += "[i]「%s」[/i]\n   对 %s 说的 · %s\n" % [
			_sanitize(str(p.get("text", ""))),
			_sanitize(str(p.get("npc", ""))),
			_fmt_ts(p.get("ts", 0)),
		]
	return out

## 语录来自 LLM 对话（source: llm-acknowledged）：过掉 bbcode 敏感字符再展示
func _sanitize(text: String) -> String:
	return text.replace("[", "").replace("]", "")

func _fmt_ts(ts) -> String:
	var t := int(ts)
	if t <= 0:
		return "未知"
	return Time.get_date_string_from_unix_time(t)

# ================= 测试接口 =================

## {open, tab, content, title}——供 dialog_check/playthrough_check 断言
func get_state() -> Dictionary:
	return {
		"open": visible,
		"tab": _current_tab,
		"content": _content.text if _content else "",
		"title": _title_label.text if _title_label else "",
	}

## 供断言直接切页（等价于点击分页按钮）
func open_tab(index: int):
	if not visible:
		open()
	_current_tab = clampi(index, 0, TAB_NAMES.size() - 1)
	_refresh()
