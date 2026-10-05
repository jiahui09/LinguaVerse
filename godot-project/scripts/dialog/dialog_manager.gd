extends Node

## 对话管理器
## 处理玩家输入 → AI 网关 → NPC 回复的完整流程
##
## 非锁定式对话（决策 9）：
## - 输入框失焦后玩家可走开，距 NPC 超过 walk_away_distance 持续 walk_away_grace_sec 自动结束
## - ESC 两段式：打字中按 ESC 退出打字；失焦后再按 ESC 结束对话
##
## 历史契约：conversation_history = 已发生的历史（assistant/user 交替），
## 当前这一句玩家输入由 _pending_input 单独携带，后端只拼一次，避免重复。

signal dialog_response_received(npc_name: String, text: String)

## 点单启发式关键词（V1 简单规则：玩家输入含其一即视为点单 → 世界反馈"咖啡端来"）
const ORDER_KEYWORDS := ["café", "cafe", "thé", "chocolat", "espresso", "cappuccino"]

@export var api_url: String = "http://localhost:3000"
@export var max_history: int = 10
@export var request_timeout_sec: float = 20.0
@export var walk_away_distance: float = 4.0
@export var walk_away_grace_sec: float = 2.0

var current_npc: Node = null
var conversation_history: Array = []
var http_request: HTTPRequest
var dialog_ui: Control

var _pending_input: String = ""
var _away_time: float = 0.0
var _request_pending: bool = false   # HTTPRequest 同一时间只允许一个请求

func _ready():
	# 注册到 group，方便查找
	add_to_group("dialog_manager")

	# 创建 HTTPRequest 节点（超时保护：后端挂起时不能让玩家永远"思考中"）
	http_request = HTTPRequest.new()
	add_child(http_request)
	http_request.timeout = request_timeout_sec
	http_request.request_completed.connect(_on_http_response)

	# 获取 UI 节点
	dialog_ui = get_node_or_null("/root/Main/DialogUI")
	if dialog_ui:
		dialog_ui.player_input_sent.connect(_on_player_input_sent)

func is_dialog_active() -> bool:
	return current_npc != null

## 玩家是否正在输入框里打字（打字时不移动、不判定走开）
func is_player_typing() -> bool:
	return dialog_ui != null and dialog_ui.has_method("is_input_focused") and dialog_ui.is_input_focused()

## 对话中的 ESC：打字中 → 退出打字；否则 → 结束对话
func _unhandled_input(event: InputEvent):
	if current_npc == null:
		return
	if event.is_action_pressed("ui_cancel"):
		if is_player_typing() and dialog_ui.has_method("release_input_focus"):
			dialog_ui.release_input_focus()
		else:
			end_dialog()
		get_viewport().set_input_as_handled()

## 走开自动结束（决策 9）：失焦状态下与 NPC 距离持续超标即自然结束
func _process(delta: float):
	if current_npc == null:
		_away_time = 0.0
		return
	if is_player_typing():
		_away_time = 0.0
		return
	var player = get_tree().get_first_node_in_group("player")
	if player == null:
		return
	var dist: float = player.global_position.distance_to(current_npc.global_position)
	if dist > walk_away_distance:
		_away_time += delta
		if _away_time >= walk_away_grace_sec:
			end_dialog()
	else:
		_away_time = 0.0

## 开始与 NPC 的对话
func start_dialog_with(npc: Node):
	current_npc = npc
	conversation_history = []
	_pending_input = ""
	_away_time = 0.0

	# 通知 NPC 开始对话
	npc.start_dialog()

	# 显示对话 UI，传入 NPC 名字和招呼语
	var npc_info = npc.get_npc_info()
	var greeting = _get_greeting(npc_info)
	if dialog_ui:
		dialog_ui.show_dialog(npc_info.name, greeting)
	# 世界内台词气泡同步显示招呼语
	if greeting and npc.has_method("show_line"):
		npc.show_line(greeting)

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
	# 上一句还没回来：不重复发（HTTPRequest 单请求限制 + UI 已禁用发送）
	if _request_pending:
		push_warning("对话请求进行中，忽略重复发送")
		return

	# 当前句单独携带，不提前写入历史（避免后端重复拼接）
	_pending_input = text
	_request_pending = true

	# 思考动作（决策 6）：等待期 NPC 做思考动作，掩盖 LLM 延迟
	_set_thinking(true)

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
	var err = http_request.request(api_url + "/api/dialog", headers, HTTPClient.METHOD_POST, json)
	if err != OK:
		# 立即失败（如请求被上一次占用以外的系统错误）：不留"思考中"死等
		_request_pending = false
		_pending_input = ""
		_set_thinking(false)
		_show_error(_friendly_error("LLM_UNAVAILABLE"))

## 统一收口：NPC 思考动作与 UI 待发送态的关闭
func _set_thinking(on: bool):
	if current_npc and current_npc.has_method("set_thinking"):
		current_npc.set_thinking(on)
	if dialog_ui and dialog_ui.has_method("set_pending"):
		dialog_ui.set_pending(on)

## HTTP 响应回调
func _on_http_response(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray):
	# 对话已被走开/ESC 结束时，丢弃迟到的响应（思考态已随 end_dialog 清理）
	if current_npc == null:
		_pending_input = ""
		_request_pending = false
		if dialog_ui and dialog_ui.has_method("set_pending"):
			dialog_ui.set_pending(false)
		return

	# 无论成功失败，先收口：结束 NPC 思考动作与 UI 待发送态（决策 6）
	_request_pending = false
	_set_thinking(false)

	if result == HTTPRequest.RESULT_TIMEOUT:
		_pending_input = ""
		_show_error(_friendly_error("LLM_TIMEOUT"))
		return

	if result != HTTPRequest.RESULT_SUCCESS:
		_pending_input = ""
		_show_error(_friendly_error("LLM_UNAVAILABLE"))
		return

	var json = JSON.new()
	var parse_result = json.parse(body.get_string_from_utf8())
	if parse_result != OK:
		_pending_input = ""
		push_warning("对话响应 JSON 解析失败")
		_show_error(_friendly_error("LLM_UNAVAILABLE"))
		return

	var response = json.data

	# 非 200：按后端稳定 code 映射友好文案，不透传底层错误
	if response_code != 200:
		var err_code := str(response.get("code", ""))
		_pending_input = ""
		_show_error(_friendly_error(err_code))
		return

	var npc_text = str(response.get("text", ""))
	var player_line := _pending_input.to_lower()

	# 把这一轮写入历史
	conversation_history.append({
		"role": "player",
		"content": _pending_input
	})
	conversation_history.append({
		"role": "assistant",
		"content": npc_text
	})
	_pending_input = ""

	# 保持历史长度
	if conversation_history.size() > max_history:
		conversation_history = conversation_history.slice(-max_history)

	# 显示 NPC 回复
	if dialog_ui:
		dialog_ui.show_npc_text(npc_text)

	# 世界内台词气泡同步这一句 + 回复到达的点头反馈
	if current_npc.has_method("show_line"):
		current_npc.show_line(npc_text)
	if current_npc.has_method("acknowledge"):
		current_npc.acknowledge()

	# 点单世界反馈（P1-4）：输入含点单关键词 → 吧台上"咖啡端来"
	if current_npc.has_method("serve_order") and _looks_like_order(player_line):
		current_npc.serve_order()

	# 发送信号
	dialog_response_received.emit(current_npc.npc_name, npc_text)

## V1 简单点单启发式（只驱动世界反馈，不参与对话逻辑，误触发无害）
func _looks_like_order(lower_text: String) -> bool:
	for keyword in ORDER_KEYWORDS:
		if lower_text.contains(keyword):
			return true
	return false

## 后端稳定 code → 玩家可见文案（展示与数据分离，禁止透传底层技术错误）
func _friendly_error(code: String) -> String:
	match code:
		"LLM_TIMEOUT":
			return "NPC 想了很久没有回应，稍后再试试"
		"LLM_UNAVAILABLE":
			return "暂时联系不上 NPC，请确认后端服务已启动"
		"LLM_MODEL_INVALID":
			return "后端的对话模型配置有问题，请联系维护者"
		"LLM_BAD_OUTPUT":
			return "NPC 这会儿说话有点语无伦次，换个说法试试"
		_:
			return "NPC 没能回话，稍后再试试"

## 显示错误信息
func _show_error(message: String):
	if dialog_ui:
		dialog_ui.show_npc_text(message)

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

## 结束对话（走开 / ESC / 外部调用的唯一出口）
func end_dialog():
	if current_npc:
		current_npc.end_dialog()
	current_npc = null
	conversation_history = []
	_pending_input = ""
	_away_time = 0.0
	# 还在飞的请求随对话一起作废，别让下一场对话被上一场的请求占住
	if _request_pending:
		http_request.cancel_request()
		_request_pending = false
	if dialog_ui:
		dialog_ui.hide_dialog()

	# 通知玩家控制器
	var player = get_tree().get_first_node_in_group("player")
	if player and player.has_method("end_dialog"):
		player.end_dialog()
