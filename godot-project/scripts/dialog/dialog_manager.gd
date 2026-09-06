extends Node

## 对话管理器
## 处理玩家输入 → AI 网关 → NPC 回复的完整流程

signal dialog_response_received(npc_name: String, text: String)
signal dialog_stream_chunk(text: String, is_done: bool)

@export var api_url: String = "http://localhost:3000"
@export var max_history: int = 10

var current_npc: Node = null
var conversation_history: Array = []
var http_request: HTTPRequest

func _ready():
	# 创建 HTTPRequest 节点
	http_request = HTTPRequest.new()
	add_child(http_request)
	http_request.request_completed.connect(_on_http_response)

## 开始与 NPC 的对话
func start_dialog_with(npc: Node):
	current_npc = npc
	conversation_history = []
	npc.start_dialog()
	# 显示对话 UI
	_show_dialog_ui()

## 发送玩家输入
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
		return
	
	if response_code != 200:
		push_error("API 返回错误: " + str(response_code))
		return
	
	var json = JSON.new()
	var parse_result = json.parse(body.get_string_from_utf8())
	if parse_result != OK:
		push_error("JSON 解析失败")
		return
	
	var response = json.data
	var npc_text = response.get("text", "")
	
	# 添加 NPC 回复到历史
	conversation_history.append({
		"role": "assistant",
		"content": npc_text
	})
	
	# 发送信号
	dialog_response_received.emit(current_npc.npc_name, npc_text)

## 获取世界状态
func _get_world_state() -> Dictionary:
	return {
		"time_of_day": "day",  # TODO: 从昼夜循环系统获取
		"player_position": Vector3.ZERO,  # TODO: 从玩家获取
	}

## 显示对话 UI
func _show_dialog_ui():
	# TODO: 通过 JavaScriptBridge 显示 DOM 对话框
	pass

## 隐藏对话 UI
func _hide_dialog_ui():
	# TODO: 通过 JavaScriptBridge 隐藏 DOM 对话框
	pass
