extends Control

## 对话 UI（Godot 原生 Control 节点）
## V1 是 Desktop 平台，不需要 JavaScriptBridge，直接用 Godot UI
##
## 打磨点（V1 收尾 P1）：
## - 待发送态（pending）：请求期间禁用发送按钮 + Enter，防重复发（HTTPRequest 单请求）
## - 思考指示带动画点（……循环），与 NPC 的思考动作（决策 6）同时发生，
##   让 LLM 延迟看起来像"对方在想怎么说"
## - 面板上写清退出方式（决策 9：ESC 两段式 / 走开自然结束），不再靠玩家自己猜

@onready var panel: PanelContainer = $PanelContainer
@onready var npc_name_label: Label = $PanelContainer/VBox/NPCName
@onready var npc_text_label: Label = $PanelContainer/VBox/NPCText
@onready var input_line: LineEdit = $PanelContainer/VBox/InputRow/Input
@onready var send_button: Button = $PanelContainer/VBox/InputRow/Send
@onready var thinking_label: Label = $PanelContainer/VBox/Thinking
@onready var hint_label: Label = $PanelContainer/VBox/Hint

signal player_input_sent(text: String)

const DOT_INTERVAL := 0.35

var _pending := false
var _dot := 0
var _dot_t := 0.0
var _npc_name := ""

func _ready():
	panel.visible = false
	thinking_label.visible = false
	send_button.pressed.connect(_on_send_pressed)
	input_line.text_submitted.connect(_on_text_submitted)

func _process(delta: float):
	if not _pending:
		return
	_dot_t += delta
	if _dot_t >= DOT_INTERVAL:
		_dot_t = 0.0
		_dot = (_dot + 1) % 3
		thinking_label.text = "%s 正在想怎么说%s" % [_npc_name, ".".repeat(_dot + 1)]

## 显示对话面板
func show_dialog(npc_name: String, greeting: String = ""):
	_npc_name = npc_name
	panel.visible = true
	npc_name_label.text = npc_name
	if greeting:
		npc_text_label.text = greeting
	input_line.text = ""
	input_line.grab_focus()
	set_pending(false)
	# 释放鼠标，让玩家可以点击 UI
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

## 隐藏对话面板
func hide_dialog():
	panel.visible = false
	set_pending(false)
	# 重新捕获鼠标
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

## 显示 NPC 回复
func show_npc_text(text: String):
	npc_text_label.text = text
	set_pending(false)

## 待发送态：请求在途（NPC 同步做思考动作）
func set_pending(on: bool):
	_pending = on
	thinking_label.visible = on
	send_button.disabled = on
	if on:
		_dot = 0
		_dot_t = 0.0
		thinking_label.text = "%s 正在想怎么说." % _npc_name

## 兼容旧调用名（= 进入待发送态）
func show_thinking():
	set_pending(true)

func is_pending() -> bool:
	return _pending

## 追加流式文本（后端接流式接口时使用，V1 暂未接入）
func append_stream_text(text: String):
	if npc_text_label.text == "" or npc_text_label.text == "…":
		npc_text_label.text = text
	else:
		npc_text_label.text += text

## 发送按钮点击
func _on_send_pressed():
	_send_input()

## 回车发送
func _on_text_submitted(_text: String):
	_send_input()

## 点击对话面板以外的画面 → 退出打字（玩家可走开，决策 9）
func _unhandled_input(event: InputEvent):
	if panel.visible and event is InputEventMouseButton and event.pressed:
		release_input_focus()

## 输入框是否处于打字状态
func is_input_focused() -> bool:
	return input_line != null and input_line.has_focus()

## 退出打字状态（ESC 第一段 / 点击画面）
func release_input_focus():
	if input_line:
		input_line.release_focus()

func _send_input():
	# 请求在途：不重复发送（按钮已禁用，这里拦键盘 Enter）
	if _pending:
		return
	var text = input_line.text.strip_edges()
	if text.is_empty():
		return
	input_line.text = ""
	player_input_sent.emit(text)
	# 发送后保持打字焦点，方便连续输入
	input_line.grab_focus()
