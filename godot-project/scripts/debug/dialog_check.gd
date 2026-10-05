extends SceneTree

## 对话链路模拟 (headless) — 触发/无后端优雅失败/ESC 两段式/走开自然结束/暂停不软锁
## 加测（V1 收尾 P1）：思考动作与待发送态（决策 6）、台词气泡/名牌、
##             对话结束后 NPC 恢复原状态（决策 9）
## 用法: godot --headless --path godot-project -s res://scripts/debug/dialog_check.gd

var failures: int = 0

func _init():
	_run()

func _check(cond: bool, label: String):
	if cond:
		print("PASS: " + label)
	else:
		failures += 1
		print("FAIL: " + label)

func _esc_event() -> InputEventAction:
	var e := InputEventAction.new()
	e.action = "ui_cancel"
	e.pressed = true
	return e

func _run():
	var scene: PackedScene = load("res://scenes/main.tscn")
	var main: Node = scene.instantiate()
	root.add_child(main)
	await process_frame
	await process_frame
	await process_frame

	var player: Node3D = main.get_node("Player")
	var dm: Node = main.get_node("DialogManager")
	var gm: Node = root.get_node_or_null("GameManager")

	# 保证"无后端"这一前提与本机是否有服务无关（拒绝连接应在毫秒级返回）
	dm.api_url = "http://127.0.0.1:3997"

	# 找 Marie
	var marie: Node3D = null
	for npc in get_nodes_in_group("npc"):
		if npc.name.begins_with("NPCWaiter"):
			marie = npc
	if marie == null:
		print("FAIL: 找不到 Marie")
		main.queue_free()
		quit(1)
		return

	# ── 1) 触发对话（模拟真实入口：先锁玩家，再 start_dialog_with）──
	# 先静态检查部署朝向：Marie 应面向街道(-X)，而不是背对顾客看后墙
	var marie_fwd: Vector3 = -marie.global_transform.basis.z
	_check(marie_fwd.dot(Vector3(-1, 0, 0)) > 0.9, "Marie 部署朝向面向街道(-X)")
	player.is_in_dialog = true
	dm.start_dialog_with(marie)
	await process_frame
	_check(dm.is_dialog_active(), "对话已开始")
	_check(dm.dialog_ui != null and dm.dialog_ui.panel.visible, "对话 UI 可见")
	_check(player.is_in_dialog, "玩家进入对话状态")
	_check(not paused, "对话中未暂停")

	# ── 1b) 名牌/气泡的可视基础（决策 6 + 名牌打磨）──
	_check(marie.get_node_or_null("BodyMesh/Eyes") != null, "NPC 眼睛已生成（转头/点头才看得见）")
	_check(marie._name_label != null and marie._name_label.billboard == BaseMaterial3D.BILLBOARD_ENABLED,
		"名牌 billboard 常朝相机")
	_check(marie.get_job_label_text() == "Serveuse de café", "名牌法语职业副标题已挂上")
	_check(marie.is_bubble_visible(), "对话开始后世界内气泡可见")
	_check(marie.get_bubble_text() == "Bonjour! Vous désirez?", "气泡显示的是招呼语")

	# ── 2) 无后端时优雅失败 + 思考动作/待发送态（决策 6）──
	dm.send_player_input("Bonjour!")
	_check(marie.is_thinking, "发送后 NPC 进入思考动作")
	_check([".", "..", "..."].has(marie.get_bubble_text()), "思考中气泡显示省略点 (got: %s)" % marie.get_bubble_text())
	_check(dm.dialog_ui.is_pending(), "请求在途进入待发送态（禁用重复发送）")
	_check(dm.dialog_ui.thinking_label.visible, "思考指示可见")
	await create_timer(1.0).timeout
	_check(dm.is_dialog_active(), "请求期间不结束对话、不崩溃")
	_check(player.is_in_dialog, "请求期间玩家状态保持")
	_check(not dm.dialog_ui.is_pending(), "响应回来后退出待发送态")
	_check(not marie.is_thinking, "响应回来后结束思考动作（不留残）")
	_check(not dm.dialog_ui.send_button.disabled, "发送按钮恢复可用")
	_check(marie.get_bubble_text() == "Bonjour! Vous désirez?",
		"错误只出现在面板里，气泡回到上一句台词 (got: %s)" % marie.get_bubble_text())

	# ── 3) ESC 两段式：打字中 → 退出打字；失焦 → 结束对话 ──
	var typed_ok := false
	dm.dialog_ui.input_line.grab_focus()
	typed_ok = dm.dialog_ui.is_input_focused()
	if typed_ok:
		dm._unhandled_input(_esc_event())
		_check(dm.is_dialog_active(), "ESC 第一段不结束对话")
		_check(not dm.dialog_ui.is_input_focused(), "ESC 第一段退出打字")
	else:
		print("SKIP: headless 无焦点环境，跳过 ESC 第一段（直接验证第二段）")
		dm.dialog_ui.release_input_focus()
	dm._unhandled_input(_esc_event())
	_check(not dm.is_dialog_active(), "ESC 结束对话")
	_check(not player.is_in_dialog, "ESC 结束后玩家输入锁释放")
	_check(not dm.dialog_ui.panel.visible, "ESC 结束后对话 UI 隐藏")
	_check(not marie.is_bubble_visible(), "ESC 结束后气泡隐藏")
	_check(not marie.is_thinking, "ESC 结束后思考态清理")
	_check(marie.current_state == marie.State.IDLE, "Marie 回到 IDLE")

	# ── 4) 走开自然结束（决策 9）──
	player.is_in_dialog = true
	dm.start_dialog_with(marie)
	await process_frame
	_check(dm.is_dialog_active(), "第二次对话已开始")
	dm.dialog_ui.release_input_focus()
	player.global_position = marie.global_position + Vector3(8.0, 0.0, 0.0)
	await create_timer(2.6).timeout
	_check(not dm.is_dialog_active(), "走开超过 4m 持续 2s 对话自然结束")
	_check(not player.is_in_dialog, "走开结束后玩家输入锁释放")
	_check(not marie.is_bubble_visible(), "走开结束后气泡隐藏")

	# 思考态残留检查：新一轮对话里 end_dialog 必须把思考动作收干净
	player.is_in_dialog = true
	dm.start_dialog_with(marie)
	await process_frame
	marie.set_thinking(true)
	_check(marie.is_thinking, "可手动置思考态（API 生效）")
	dm.end_dialog()
	_check(not marie.is_thinking, "end_dialog 清除思考动作")
	_check(not player.is_in_dialog, "清理后玩家输入锁释放")

	# ── 5) 暂停不软锁：对话中 ESC 不触发暂停；无对话时暂停可恢复 ──
	if gm != null:
		player.is_in_dialog = true
		dm.start_dialog_with(marie)
		await process_frame
		dm.dialog_ui.release_input_focus()
		gm._unhandled_input(_esc_event())
		_check(not paused, "对话中 ESC 不触发暂停（dialog_manager 消费）")
		dm.end_dialog()
		_check(not player.is_in_dialog, "end_dialog 外部调用同样释放锁")

		gm._unhandled_input(_esc_event())
		_check(paused, "无对话时 ESC 进入暂停")
		gm._unhandled_input(_esc_event())
		_check(not paused, "暂停后 ESC 能恢复（PROCESS_MODE_ALWAYS）")
	else:
		print("SKIP: 未注册 GameManager 自动加载，跳过暂停断言")

	# ── 6) 对话结束后 NPC 回到自己原本的行为（决策 9）──
	var pierre: Node3D = null
	for npc in get_nodes_in_group("npc"):
		if npc.name.begins_with("NPCPedestrian"):
			pierre = npc
	if pierre != null:
		var before: int = pierre.current_state
		_check(before == pierre.State.WALK, "Pierre 平时在走路")
		pierre.start_dialog()
		_check(pierre.current_state == pierre.State.TALKING, "Pierre 对话中停步面向玩家")
		pierre.end_dialog()
		_check(pierre.current_state == before, "对话结束后 Pierre 恢复走路（决策 9）")
	else:
		print("SKIP: 找不到 Pierre，跳过状态恢复断言")

	# ── 7) 环境音接线（P1-5）：节点在场 + 区域淡变（素材未导入则诚实 SKIP）──
	var amb: Node = main.get_node_or_null("Ambience")
	_check(amb != null, "环境音节点已接入场景")
	var street_wav := "res://assets/audio/ambient/street_loop.wav"
	var cafe_wav := "res://assets/audio/ambient/cafe_loop.wav"
	if amb != null and ResourceLoader.exists(street_wav) and ResourceLoader.exists(cafe_wav):
		_check(amb.is_street_playing(), "街道环境音在循环播放")
		# 先把玩家摆到街面已知点（前面的对话测试把玩家留在了店内区域 x>6）
		var zone_y: float = player.global_position.y
		player.global_position = Vector3(0.0, zone_y, -10.0)
		await create_timer(1.2).timeout
		var g0: Array = amb.get_gains()
		_check(g0[0] > 0.5 and g0[1] < 0.1, "街面区域: 街道音为主、室内音静音 (gains=%s)" % [g0])
		player.global_position = Vector3(8.0, zone_y, 4.34)
		await create_timer(1.2).timeout
		var g1: Array = amb.get_gains()
		_check(g1[1] > 0.9 and g1[0] < 0.1, "进店后交叉淡变: 室内音为主、街道音静音 (gains=%s)" % [g1])
	else:
		print("SKIP: 环境音素材未就绪，跳过播放/淡变断言")

	main.queue_free()
	if failures > 0:
		print("DIALOG_FAIL: %d 项失败" % failures)
		quit(1)
	else:
		print("DIALOG_ALL_PASS")
		quit(0)
