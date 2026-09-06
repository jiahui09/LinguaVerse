extends Control

## 对话 UI（Godot 原生 Control 节点）
## V1 是 Desktop 平台，不需要 JavaScriptBridge，直接用 Godot UI

@onready var panel: PanelContainer = $PanelContainer
@onready var npc_name_label: Label = $PanelContainer/VBox/NPCName
@onready var npc_text_label: Label = $PanelContainer/VBox/NPCText
@onready var input_line: LineEdit = $PanelContainer/VBox/InputRow/Input
@onready var send_button: Button = $PanelContainer/VBox/InputRow/Send
@onready var thinking_label: Label = $PanelContainer/VBox/Thinking

signal player_input_sent(text: String)

func _ready():
	panel.visible = false
	thinking_label.visible = false
	send_button.pressed.connect(_on_send_pressed)
	input_line.text_submitted.connect(_on_text_submitted)

## 显示对话面板
func show_dialog(npc_name: String, greeting: String = ""):
	panel.visible = true
	npc_name_label.text = npc_name
	if greeting:
		npc_text_label.text = greeting
	input_line.text = ""
	input_line.grab_focus()
	# 释放鼠标，让玩家可以点击 UI
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

## 隐藏对话面板
func hide_dialog():
	panel.visible = false
	thinking_label.visible = false
	# 重新捕获鼠标
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

## 显示 NPC 回复
func show_npc_text(text: String):
	npc_text_label.text = text
	thinking_label.visible = false

## 显示"思考中"动画
func show_thinking():
	thinking_label.visible = true
	npc_text_label.text = ""

## 追加流式文本
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

func _send_input():
	var text = input_line.text.strip_edges()
	if text.is_empty():
		return
	input_line.text = ""
	player_input_sent.emit(text)
	show_thinking()
