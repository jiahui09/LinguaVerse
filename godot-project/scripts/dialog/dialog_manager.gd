extends Node

## 对话管理器
## 处理玩家输入 → AI 网关 → NPC 回复的完整流程

signal dialog_response_received(npc_name: String, text: String)

@export var api_url: String = "http://localhost:3000"
@export var max_history: int = 10

var current_npc: Node = null
var conversation_history: Array = []
var http_request: HTTPRequest
var dialog_ui: Control

func _ready():
	# 注册到 group，方便查找
	add_to_group("dialog_manager")

	# 创建 HTTPRequest 节点
	http_request = HTTPRequest.new()
	add_child(http_request)
	http_request.request_completed.connect(_on_http_response)

	# 获取 UI 节点
	dialog_ui = get_node_or_null("/root/Main/DialogUI")
	if dialog_ui:
		dialog_ui.player_input_sent.connect(_on_player_input_sent)

## 开始与 NPC 的对话
func start_dialog_with(npc: Node):
	current_npc = npc
	conversation_history = []

	# 通知 NPC 开始对话
	npc.start_dialog()

	# 显示对话 UI，传入 NPC 名字和招呼语
	var npc_info = npc.get_npc_info()
	var greeting = _get_greeting(npc_info)
	if dialog_ui:
		dialog_ui.show_dialog(npc_info.name, greeting)

	# 把招呼语加入对话历史
	if greeting:
		conversation_history.append({
			"role": "assistant",
			"content": greeting
		})

## 获取 NPC 招呼语（V1 简单处理）
func _get_greeting(npc_info: Dictionary) -> String:
	var job = npc_info.get("job", "")
	if "服务员" in job or "serveuse" in job:
		return "Bonjour! Vous désirez?"
	elif "路人" in job or "Pierre" in npc_info.get("name", ""):
		return "Salut."
	elif "老人" in job or "Jean" in npc_info.get("name", ""):
		return "Bonjour, jeune voisin!"
	return "Bonjour!"

## 玩家输入回调（来自 DialogUI）
func _on_player_input_sent(text: String):
	send_player_input(text)

## 发送玩家输入到 AI 网关
func send_player_input(text: String):
	if current_npc == null:
		return

	# 添加到对话历史
	conversation_history.append({
		"role": "player",
		"content": text
	})

	# 保持历史长度
	if conversation_history.size() > max_history:
		conversation_history = conversation_history.slice(-max_history)

	# 组装请求
	var npc_info = current_npc.get_npc_info()
	var request_body = {
		"player_input": text,
		"npc_info": npc_info,
		"conversation_history": conversation_history,
		"world_state": _get_world_state()
	}

	# 发送 HTTP 请求
	var json = JSON.stringify(request_body)
	var headers = ["Content-Type: application/json"]
	http_request.request(api_url + "/api/dialog", headers, HTTPClient.METHOD_POST, json)

## HTTP 响应回调
func _on_http_response(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray):
	if result != HTTPRequest.RESULT_SUCCESS:
		push_error("HTTP 请求失败: " + str(result))
		_show_error("连接失败，请确认后端已启动")
		return

	if response_code != 200:
		push_error("API 返回错误: " + str(response_code))
		_show_error("服务器错误: " + str(response_code))
		return

	var json = JSON.new()
	var parse_result = json.parse(body.get_string_from_utf8())
	if parse_result != OK:
		push_error("JSON 解析失败")
		_show_error("响应格式错误")
		return

	var response = json.data
	var npc_text = response.get("text", "")

	# 添加 NPC 回复到历史
	conversation_history.append({
		"role": "assistant",
		"content": npc_text
	})

	# 显示 NPC 回复
	if dialog_ui:
		dialog_ui.show_npc_text(npc_text)

	# 发送信号
	dialog_response_received.emit(current_npc.npc_name, npc_text)

## 显示错误信息
func _show_error(message: String):
	if dialog_ui:
		dialog_ui.show_npc_text("[Erreur] " + message)

## 获取世界状态
func _get_world_state() -> Dictionary:
	var time_of_day = "day"
	var player_pos = Vector3.ZERO

	# 从昼夜循环获取时间
	var sun = get_node_or_null("/root/Main/Sun")
	if sun and sun.has_method("get_time_of_day"):
		time_of_day = sun.get_time_of_day()

	# 从玩家获取位置
	var player = get_tree().get_first_node_in_group("player")
	if player:
		player_pos = player.global_position

	return {
		"time_of_day": time_of_day,
		"player_position": {"x": player_pos.x, "y": player_pos.y, "z": player_pos.z},
	}

## 结束对话
func end_dialog():
	if current_npc:
		current_npc.end_dialog()
	current_npc = null
	conversation_history = []
	if dialog_ui:
		dialog_ui.hide_dialog()

	# 通知玩家控制器
	var player = get_tree().get_first_node_in_group("player")
	if player and player.has_method("end_dialog"):
		player.end_dialog()
