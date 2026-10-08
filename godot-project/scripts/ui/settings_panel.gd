extends CanvasLayer

## P3 批次3：设置面板 + 暂停浮层（决策 26 操作体验清单）
## - 由 GameManager.game_paused / game_resumed 驱动显隐；process_mode=ALWAYS 以便暂停中操作
## - 控件直连 gm.set_setting（白名单+范围钳制+立即生效+user://settings.json 落盘），
##   本层不维护第二份状态（展示与数据分离，数据源唯一在 GameManager）
## - 暂停态 ESC 恢复走 GameManager._unhandled_input（对话/手册打开时不经过本面板）

const TITLE_TEXT := "设置 · Réglages"
const ROWS := [
	# key, 显示名, 最小, 最大, 步进, 值格式
	["mouse_sensitivity", "视角灵敏度", 0.0005, 0.02, 0.0005, "%.4f"],
	["volume", "音量", 0.0, 1.0, 0.05, "%.2f"],
	["fov", "视野 (FOV)", 60.0, 100.0, 1.0, "%.0f°"],
]

var sliders: Dictionary = {}          # key -> HSlider（测试/断言直取）
var fullscreen_check: CheckBox
var resume_button: Button
var _panel: PanelContainer
var _labels: Dictionary = {}          # key -> Label（数值回显）
var _gm: Node
var _syncing: bool = false

func _ready():
	layer = 30
	process_mode = Node.PROCESS_MODE_ALWAYS   # 树暂停时仍可操作（暂停不软锁）
	add_to_group("settings_panel")
	_gm = get_node_or_null("/root/GameManager")
	_build_ui()
	if _gm != null:
		_gm.game_paused.connect(show_panel)
		_gm.game_resumed.connect(hide_panel)
		_gm.settings_changed.connect(_on_setting_changed)
	visible = false

func _build_ui() -> void:
	# 全屏压暗层（吞掉点击，防止点穿到世界）
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.55)
	dim.anchor_right = 1.0
	dim.anchor_bottom = 1.0
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	# 居中面板
	var panel := PanelContainer.new()
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.anchor_top = 0.5
	panel.anchor_bottom = 0.5
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	panel.custom_minimum_size = Vector2(460, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.09, 0.09, 0.12, 0.97)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(24)
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)
	_panel = panel

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 16)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = TITLE_TEXT
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	vbox.add_child(title)

	for row in ROWS:
		vbox.add_child(_make_row(str(row[0]), str(row[1]),
			float(row[2]), float(row[3]), float(row[4]), str(row[5])))

	fullscreen_check = CheckBox.new()
	fullscreen_check.text = "全屏"
	if _gm != null:
		fullscreen_check.button_pressed = bool(_gm.get_setting("fullscreen"))
	fullscreen_check.toggled.connect(_on_fullscreen_toggled)
	vbox.add_child(fullscreen_check)

	resume_button = Button.new()
	resume_button.text = "继续游戏 · ESC"
	resume_button.pressed.connect(_on_resume_pressed)
	vbox.add_child(resume_button)

func _make_row(key: String, title: String, mn: float, mx: float, step: float, fmt: String) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)

	var head := HBoxContainer.new()
	var name_label := Label.new()
	name_label.text = title
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(name_label)
	var value_label := Label.new()
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.add_theme_color_override("font_color", Color(1.0, 0.86, 0.55))
	head.add_child(value_label)
	box.add_child(head)
	_labels[key] = value_label

	var slider := HSlider.new()
	slider.min_value = mn
	slider.max_value = mx
	slider.step = step
	slider.value = float(_gm.get_setting(key)) if _gm != null else mn
	slider.value_changed.connect(func(v: float): _on_slider_changed(key, v))
	box.add_child(slider)
	sliders[key] = slider
	_labels[key].text = fmt % slider.value
	return box

func _on_slider_changed(key: String, value: float) -> void:
	if _syncing:
		return
	if _gm != null:
		_gm.set_setting(key, value)   # 钳制/落盘/广播全在 gm（唯一数据源）

func _on_fullscreen_toggled(pressed: bool) -> void:
	if _syncing:
		return
	if _gm != null:
		_gm.set_setting("fullscreen", pressed)

func _on_setting_changed(key: String, value: Variant) -> void:
	# gm 广播 → 回显/滑条跟值（_syncing 防回环）
	if not _labels.has(key):
		return
	_syncing = true
	if sliders.has(key):
		var s: HSlider = sliders[key]
		if not is_equal_approx(s.value, float(value)):
			s.value = float(value)
	var fmt := "%.2f"
	for row in ROWS:
		if str(row[0]) == key:
			fmt = str(row[5])
			break
	_labels[key].text = fmt % float(value)
	if key == "fullscreen" and fullscreen_check != null:
		fullscreen_check.button_pressed = bool(value)
	_syncing = false

func _on_resume_pressed() -> void:
	if _gm != null:
		_gm.toggle_pause()

func show_panel() -> void:
	visible = true

func hide_panel() -> void:
	visible = false

## 测试/断言快照
func get_state() -> Dictionary:
	var values := {}
	for key in sliders:
		values[key] = sliders[key].value
	return {
		"visible": visible,
		"values": values,
		"fullscreen": fullscreen_check.button_pressed if fullscreen_check != null else null,
	}
