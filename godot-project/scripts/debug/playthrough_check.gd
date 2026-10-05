extends SceneTree

## 闭环回放 (P0-B4) — 真实输入链路端到端：
##   mock 后端 → 射线识别 NPC → E 键路径开对话 → 打字锁/失焦可走 → 多轮对话(历史契约)
##   → 错误路径友好文案 → 走开自然结束 → 第二个 NPC + ESC 两段式 → 昼夜联动
##
## 用法: tools/verify.sh 自动运行；或手动：
##   godot --headless --path godot-project -s res://scripts/debug/playthrough_check.gd
## 退出码: 0=全部通过, >0=失败项数, 77=跳过（node/mock 不可用，不伪装通过）

const MOCK_PORT := 3001
const MOCK_URL := "http://127.0.0.1:3001"
## 与 tools/mock_llm_server.mjs 的 SCRIPT 一致（脚本变化需两处同步）
const SCRIPT_LINES := [
	"Bonjour! Bienvenue au café.",
	"Très bien, un café crème. Un instant, s’il vous plaît.",
	"Voilà votre café. Bonne journée!",
	"Merci à vous, au revoir!",
	"D’accord, je vous écoute.",
]

var failures := 0

func _init():
	_run()

func _check(cond: bool, label: String):
	if cond:
		print("PASS: " + label)
	else:
		failures += 1
		print("FAIL: " + label)

func _quit_all(code: int):
	# 无论如何不泄漏后台 mock 进程
	await _http(HTTPClient.METHOD_POST, MOCK_URL + "/__shutdown", "{}")
	quit(code)

func _http(method: int, url: String, body: String = "") -> Dictionary:
	var hr := HTTPRequest.new()
	hr.timeout = 15.0
	root.add_child(hr)
	var err := hr.request(url, PackedStringArray(["Content-Type: application/json"]), method, body)
	if err != OK:
		hr.queue_free()
		return {"status": 0, "body": {}}
	var res: Array = await hr.request_completed
	hr.queue_free()
	var parsed = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
	return {"status": res[1] as int, "body": parsed}

func _wait_for(pred: Callable, timeout: float) -> bool:
	var t := 0.0
	while t < timeout:
		if pred.call():
			return true
		await create_timer(0.1).timeout
		t += 0.1
	return pred.call()

## 玩家视线对准 NPC 胶囊中心（相机 y=1.5 高于胶囊顶 1.2，水平视线会擦头，
## 真实游玩需鼠标下压——此处等价于玩家看向对方）
func _aim_at(player: Node3D, npc: Node3D) -> void:
	var cam: Camera3D = player.camera
	var from: Vector3 = cam.global_position
	var to: Vector3 = npc.global_position + Vector3(0, 0.6, 0)
	var dir: Vector3 = (to - from).normalized()
	var yaw := atan2(-dir.x, -dir.z)
	var pitch := asin(clampf(dir.y, -1.0, 1.0))
	player.yaw = yaw
	player.pitch = pitch
	player.rotation.y = yaw
	cam.rotation.x = pitch

func _run():
	# ── 0) mock 后端：可达则复用，不可达则自启，仍不可用 → 明确 SKIP ──
	var probe: Dictionary = await _http(HTTPClient.METHOD_GET, MOCK_URL + "/api/health")
	var mock_ok: bool = int(probe.get("status", 0)) == 200
	if not mock_ok:
		# node 不存在或 mock 起不来，健康探测都不会通过 → 统一走 SKIP
		var mock_path := ProjectSettings.globalize_path("res://../tools/mock_llm_server.mjs")
		OS.create_process("node", PackedStringArray([mock_path]))
		for i in 20:
			await create_timer(0.25).timeout
			var p2: Dictionary = await _http(HTTPClient.METHOD_GET, MOCK_URL + "/api/health")
			if int(p2.get("status", 0)) == 200:
				mock_ok = true
				break
		if not mock_ok:
			print("PLAYTHROUGH_SKIP: mock 后端启动失败（node 不可用？）")
			await _quit_all(77)
			return

	# ── 装载主场景 ──
	var scene: PackedScene = load("res://scenes/main.tscn")
	var main: Node = scene.instantiate()
	root.add_child(main)
	await process_frame
	await process_frame
	await process_frame

	var player: Node3D = main.get_node("Player")
	var dm: Node = main.get_node("DialogManager")
	var ui: Node = dm.dialog_ui
	var gen: Node = main.get_node("StreetGenerator")
	dm.api_url = MOCK_URL

	var marie: Node3D = null
	var jean: Node3D = null
	for npc in get_nodes_in_group("npc"):
		if npc.name.begins_with("NPCWaiter"):
			marie = npc
		elif npc.name.begins_with("NPCElder"):
			jean = npc
	if marie == null or jean == null:
		print("FAIL: NPC 缺失 (marie=%s jean=%s)" % [marie, jean])
		main.queue_free()
		await _quit_all(maxi(1, failures))
		return

	# ── 1) 射线识别 + E 键路径开对话（真实入口 _try_start_dialog）──
	var start_y := player.global_position.y
	player.global_position = Vector3(marie.global_position.x - 1.4, start_y, marie.global_position.z)
	_aim_at(player, marie)
	for i in 4:
		await physics_frame
	var ray = player.interaction_ray
	_check(ray.get_target() == marie, "射线在 1.5m 内识别 Marie")
	player._try_start_dialog()
	await process_frame
	_check(dm.is_dialog_active(), "E 键路径开对话成功")
	if not dm.is_dialog_active():
		# 射线路径失败已记 FAIL；直接开对话以继续验证后续链路
		player.is_in_dialog = true
		dm.start_dialog_with(marie)
		await process_frame
	_check(player.is_in_dialog, "玩家输入锁已置位")

	# ── 2) 打字锁 / 失焦可走（决策 9 的移动语义）──
	Input.action_press("move_forward")
	await physics_frame
	_check(ui.is_input_focused(), "开对话后输入框自动聚焦(打字中)")
	var v_blocked: Vector3 = player.velocity
	_check(absf(v_blocked.z) < 0.1 and absf(v_blocked.x) < 0.1, "打字中 WASD 不移动玩家")
	ui.release_input_focus()
	await physics_frame
	await physics_frame
	var v_free: Vector3 = player.velocity
	_check(Vector3(v_free.x, 0, v_free.z).length() > 1.0, "失焦后 WASD 可走开 (v=%.2f)" % Vector3(v_free.x, 0, v_free.z).length())
	Input.action_release("move_forward")
	await physics_frame

	# ── 3) 多轮对话：历史契约（greeting+user+assistant，交替且不重复当前句）──
	dm.send_player_input("un café, s’il vous plaît")
	_check(marie.is_thinking, "发送后 Marie 进入思考动作（决策 6）")
	_check([".", "..", "..."].has(marie.get_bubble_text()), "思考中气泡显示省略点")
	_check(ui.is_pending(), "请求在途进入待发送态（禁用重复发送）")
	var ok1 := await _wait_for(func(): return dm.conversation_history.size() >= 3, 10.0)
	_check(ok1, "第 1 轮收到回复")
	var text1: String = str(ui.npc_text_label.text)
	_check(SCRIPT_LINES.has(text1), "回复 == mock 固定脚本第 N 句 (got: %s)" % text1)
	_check(not marie.is_thinking and not ui.is_pending(), "回复到达后思考动作/待发送态收口")
	_check(marie.get_bubble_text() == text1, "气泡显示 NPC 这一句台词")
	_check(marie.get_served_count() == 1, "点单后吧台上多一杯咖啡（世界反馈 P1-4）")
	var h1: Array = dm.conversation_history
	_check(h1.size() == 3 and h1[0]["role"] == "assistant" and h1[1]["role"] == "player" and h1[2]["role"] == "assistant", "历史契约: assistant/player/assistant 交替")

	dm.send_player_input("merci beaucoup")
	var ok2 := await _wait_for(func(): return dm.conversation_history.size() >= 5, 10.0)
	_check(ok2, "第 2 轮收到回复")
	var h2: Array = dm.conversation_history
	_check(h2.size() == 5 and h2[3]["role"] == "player" and h2[4]["role"] == "assistant", "第 2 轮历史正确累积")

	# ── 4) 错误路径：稳定 code → 前端友好文案，且不污染历史 ──
	await _http(HTTPClient.METHOD_POST, MOCK_URL + "/__mode", "{\"mode\":\"fail\"}")
	dm.send_player_input("et un thé aussi?")
	var got_err := await _wait_for(func(): return str(ui.npc_text_label.text).find("稍后再试试") >= 0, 8.0)
	_check(got_err, "错误 code 映射为友好中文文案")
	_check(dm.conversation_history.size() == 5, "错误不污染对话历史")
	_check(dm.is_dialog_active(), "请求失败不结束对话")
	_check(not marie.is_thinking, "错误路径同样结束思考动作")
	_check(marie.get_bubble_text() == str(dm.conversation_history[4]["content"]),
		"错误只在面板里，气泡回到上一句 NPC 台词")
	await _http(HTTPClient.METHOD_POST, MOCK_URL + "/__mode", "{\"mode\":\"ok\"}")

	# ── 5) 走开自然结束（失焦状态下）──
	ui.release_input_focus()
	player.global_position = Vector3(marie.global_position.x - 9.0, start_y, marie.global_position.z)
	await create_timer(2.6).timeout
	_check(not dm.is_dialog_active(), "走开 >4m 持续 2s 对话自然结束")
	_check(not ui.panel.visible, "结束后对话 UI 隐藏")
	_check(dm.conversation_history.is_empty(), "结束后历史清空")
	_check(not player.is_in_dialog, "结束后玩家输入锁释放")
	_check(not marie.is_bubble_visible() and not marie.is_thinking, "走开结束后气泡与思考态一并清理")

	# ── 6) 第二个 NPC（Jean）+ ESC 两段式退出 ──
	player.global_position = Vector3(jean.global_position.x, start_y, jean.global_position.z + 1.5)
	_aim_at(player, jean)
	for i in 4:
		await physics_frame
	var ray2 = player.interaction_ray
	_check(ray2.get_target() == jean, "射线识别 Jean")
	player._try_start_dialog()
	await process_frame
	_check(dm.is_dialog_active(), "第二个 NPC 对话可开启")
	dm.send_player_input("bonjour")
	var ok3 := await _wait_for(func(): return dm.conversation_history.size() >= 3, 10.0)
	_check(ok3, "第二个 NPC 正常回复")
	var esc := InputEventAction.new()
	esc.action = "ui_cancel"
	esc.pressed = true
	dm._unhandled_input(esc)
	_check(dm.is_dialog_active() and not ui.is_input_focused(), "ESC 第一段: 退出打字")
	dm._unhandled_input(esc)
	_check(not dm.is_dialog_active(), "ESC 第二段: 结束对话")
	_check(not jean.is_bubble_visible() and not jean.is_thinking, "ESC 结束后 Jean 气泡与思考态清理")

	# ── 7) 昼夜联动（world_state 数据源）──
	var sun: Node = main.get_node("Sun")
	sun.fixed_hour = 21.0
	sun._update_time()
	sun._update_light()
	_check(sun.get_time_of_day() == "night", "fixed_hour=21 → night")
	_check(str(dm._get_world_state()["time_of_day"]) == "night", "world_state.time_of_day 正确")
	sun.fixed_hour = 14.5
	sun._update_time()

	# ── 8) 布局自洽（与 street_check 相同口径，防回放脚本用错环境）──
	var cafe_b := 0
	for b in gen.layout.get("buildings", []):
		if b.get("is_cafe", false):
			cafe_b += 1
	_check(cafe_b == 1, "布局含且仅含 1 个咖啡馆")

	main.queue_free()
	if failures > 0:
		print("PLAYTHROUGH_FAIL: %d 项失败" % failures)
		await _quit_all(mini(failures, 100))
	else:
		print("PLAYTHROUGH_ALL_PASS")
		await _quit_all(0)
