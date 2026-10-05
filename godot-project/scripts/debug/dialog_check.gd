extends SceneTree

## 对话链路模拟 (headless) — 触发/无后端优雅失败/ESC 两段式/走开自然结束/暂停不软锁
## 加测（V1 收尾 P1）：思考动作与待发送态（决策 6）、台词气泡/名牌、
##             对话结束后 NPC 恢复原状态（决策 9）
## 加测（操作逻辑 P2）：二次招呼记忆（决策 14 升级）、新居民手册三钩子与三分页、
##             E 目标提示与键位条淡出、设置接线（灵敏度/音量）、幂等入账
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

	# 手册存档改写到项目内临时文件（headless 沙箱 user:// 不可写；结束时清理）
	if gm != null:
		gm.handbook_path = "res://handbook_test_tmp.json"
		gm.reset_handbook()

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

	# ── 8) 操作逻辑 P2（docs/操作逻辑-设计与实施.md）：
	#    二次招呼记忆 / 新居民手册三钩子与三分页 / E 提示与键位条 / 设置接线 ──
	if gm != null:
		gm.reset_handbook()   # 本节数据隔离：只验本节产生的记录

		# 8a) 二次招呼记忆（决策 14 升级）
		player.is_in_dialog = true
		dm.start_dialog_with(marie)
		await process_frame
		_check(str(marie.get_bubble_text()).to_lower().find("revoilà") >= 0,
			"老相识 Marie 用记忆招呼语 (got: %s)" % marie.get_bubble_text())
		_check(gm.handbook.npcs.has("Marie") and int(gm.handbook.npcs["Marie"].get("meetings", 0)) == 1,
			"手册·邻里：本场会面记 1 次")
		dm.end_dialog()

		var jean: Node3D = null
		for npc in get_nodes_in_group("npc"):
			if npc.name.begins_with("NPCElder"):
				jean = npc
		if jean != null:
			player.is_in_dialog = true
			dm.start_dialog_with(jean)
			await process_frame
			_check(str(jean.get_bubble_text()).to_lower().find("revoilà") < 0,
				"Jean 初次见面用初次招呼 (got: %s)" % jean.get_bubble_text())
			dm.end_dialog()
			player.is_in_dialog = true
			dm.start_dialog_with(jean)
			await process_frame
			_check(str(jean.get_bubble_text()).to_lower().find("revoilà") >= 0,
				"Jean 再次见面认出玩家 (got: %s)" % jean.get_bubble_text())
			_check(int(gm.handbook.npcs.get("Jean", {}).get("meetings", 0)) == 2,
				"手册·邻里：Jean 会面累计 2 次")
			dm.end_dialog()
		else:
			print("SKIP: 找不到 Jean，跳过初次/记忆招呼对比")

		# 8b) 手册·语录：幂等按句去重（大小写不敏感）
		var pcount0: int = gm.handbook.phrases.size()
		_check(gm.record_phrase("Un café, s'il vous plaît", "Marie"), "语录首次入账")
		_check(not gm.record_phrase("un café, s'il vous plaît", "Marie") and gm.handbook.phrases.size() == pcount0 + 1,
			"同句重复不重复计（去重大小写不敏感）")

		# 8c) 手册·足迹与时段（规则 1：探索即进度，静默记录）
		var py: float = player.global_position.y
		player.global_position = Vector3(0.0, py, 30.0)
		gm._poll_world_state()
		_check(gm.handbook.zones.has("street_north"), "足迹：进入北段被记录")
		player.global_position = Vector3(8.0, py, 4.34)
		gm._poll_world_state()
		_check(gm.handbook.zones.has("cafe"), "足迹：进入咖啡馆被记录")
		_check(not gm.record_zone("street_north"), "重复进入同段不重复计")
		gm.record_daypart("dawn")
		_check(not gm.record_daypart("dawn") and gm.handbook.dayparts.has("dawn"), "时段记录幂等：再次记录返回 false")

		# 8d) 手册 UI：开合、三分页、空状态、ESC 不误触暂停
		var hb: Node = main.get_node("Handbook")
		_check(hb != null and not hb.visible, "手册初始关闭")
		hb.open()
		_check(hb.visible, "手册可打开")
		_check(player.ui_blocked, "打开手册冻结移动输入")
		hb.open_tab(0)
		var st: Dictionary = hb.get_state()
		var c0 := str(st["content"])
		_check(c0.find("Rue des Rosiers") >= 0 or c0.find("Café") >= 0,
			"足迹页显示已到过的街段 (前60字: %s)" % c0.left(60))
		hb.open_tab(1)
		var c1 := str(hb.get_state()["content"])
		_check(c1.find("Marie") >= 0 and c1.find("Jean") >= 0, "邻里页显示已认识的 NPC")
		hb.open_tab(2)
		var c2 := str(hb.get_state()["content"])
		_check(c2.find("Un café") >= 0, "语录页显示已记录句子")
		_check(c2.find("分数") < 0, "语录页不含评分字样（规则 6）")
		gm.reset_handbook()
		hb.open_tab(0)
		_check(str(hb.get_state()["content"]).find("还没有足迹") >= 0, "足迹空状态文案")
		hb.close()
		_check(not hb.visible and not player.ui_blocked, "关闭手册释放输入")
		hb.open()
		hb._unhandled_input(_esc_event())
		_check(not hb.visible, "ESC 关闭手册")
		_check(not paused, "关手册不进入暂停")

		# 8e) E 目标提示与底部键位条（操作逻辑 §1.2 / §2.2）
		var hud: Node = main.get_node("HudHints")
		if hud != null:
			var hst: Dictionary = hud.get_state()
			_check(str(hst["tip_text"]).find("WASD") >= 0 and str(hst["tip_text"]).find("Tab") >= 0,
				"底部键位条含 WASD/Tab")
			hud._on_target_found(marie)
			hst = hud.get_state()
			_check(bool(hst["hint_visible"]) and str(hst["hint_text"]).begins_with("E · Parler à Marie"),
				"命中 NPC 浮现 E 提示 (got: %s)" % hst["hint_text"])
			player.is_in_dialog = true
			dm.start_dialog_with(marie)
			await process_frame
			hud._on_target_found(marie)
			_check(not bool(hud.get_state()["hint_visible"]), "对话中不显示 E 提示")
			dm.end_dialog()
			hud._on_target_lost()
			_check(not bool(hud.get_state()["hint_visible"]), "目标丢失提示消失")
			for k in ["move", "look", "interact", "handbook"]:
				hud.mark_used(k)
			_check(bool(hud.get_state()["tips_faded"]), "四个键位都用过后键位条淡出（教学完成即退场）")
		else:
			print("SKIP: 找不到 HudHints，跳过提示层断言")

		# 8f) 设置接线（此前 settings 存了从不读）
		gm.set_setting("mouse_sensitivity", 0.005)
		_check(is_equal_approx(player.mouse_sensitivity, 0.005), "灵敏度设置即刻生效于玩家视角")
		gm.set_setting("volume", 0.1)
		_check(absf(AudioServer.get_bus_volume_db(0) - linear_to_db(0.1)) < 0.05,
			"音量设置接到 Master 总线 (db=%.2f)" % AudioServer.get_bus_volume_db(0))
		gm.set_setting("volume", 0.8)
		gm.set_setting("mouse_sensitivity", 0.002)

		# 清理本节测试存档
		if FileAccess.file_exists("res://handbook_test_tmp.json"):
			DirAccess.remove_absolute(ProjectSettings.globalize_path("res://handbook_test_tmp.json"))
	else:
		print("SKIP: 未注册 GameManager，跳过手册/提示/设置断言")

	main.queue_free()
	if failures > 0:
		print("DIALOG_FAIL: %d 项失败" % failures)
		quit(1)
	else:
		print("DIALOG_ALL_PASS")
		quit(0)
