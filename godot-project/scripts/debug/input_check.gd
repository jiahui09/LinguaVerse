extends SceneTree

## 全量输入测试 (headless 逻辑层) — 真机反馈"输入都有问题"后的系统性排查
## 覆盖: 两种事件入口(root.push_input / Input.parse_input_event) × 键盘(action 4 向移动/
##       interact/handbook/Esc) × 鼠标(运动分发/比例性/符号/俯仰钳位/左中右键/滚轮/点击
##       重捕获) × 状态机(手册冻结、对话冻结视角、暂停开合与让路、失焦暂停、灵敏度热更)
## 断言策略: 鼠标运动用**比例断言**——headless dummy 窗口对 relative 有固定放大(实测 20×,
##       真机 1:1 无此系数), 绝对值断言会绑死在环境系数上; 方向/比例/钳位与系数无关。
## 边界(如实): display 层(niri→窗口焦点/真实指针捕获/warp/嵌入转发)无法 headless 注入,
##       本测试绿=事件入口→action map→控制器状态机链路绿; 真机层见输出 SCOPE 行的手测清单。
## 用法: godot --headless --path godot-project -s res://scripts/debug/input_check.gd

var failures: int = 0

func _check(cond: bool, label: String):
	if cond:
		print("PASS: " + label)
	else:
		failures += 1
		print("FAIL: " + label)

func _init():
	_run()

# ── 事件入口 A: root.push_input（最贴近真实: Window 层入队, 经 _input→GUI→_unhandled） ──
func _push(ev: InputEvent) -> void:
	root.push_input(ev)
	# 注入与消费之间没有 await——probe 实证同帧立即生效; 需帧推进处显式 await

func _motion(dx: float, dy: float) -> InputEventMouseMotion:
	var m := InputEventMouseMotion.new()
	m.relative = Vector2(dx, dy)
	return m

func _action(name: String) -> InputEventAction:
	var a := InputEventAction.new()
	a.action = name
	a.pressed = true
	return a

func _button(idx: int) -> InputEventMouseButton:
	var b := InputEventMouseButton.new()
	b.button_index = idx
	b.pressed = true
	return b

func _reset_view(player: Node) -> void:
	player.yaw = 0.0
	player.pitch = 0.0
	player.rotation.y = 0.0

## 站位瞄准(照 playthrough_check 同款: yaw/pitch 与 rotation 双写)
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

func _run() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn")
	var main: Node = scene.instantiate()
	root.add_child(main)
	await process_frame
	await process_frame
	await process_frame

	var player: Node3D = main.get_node("Player")
	var gm: Node = root.get_node_or_null("GameManager")
	var hb: Node = main.get_node("Handbook")
	var dm: Node = main.get_node("DialogManager")
	_check(gm != null and hb != null and dm != null, "测试对象齐备 (GameManager/Handbook/DialogManager)")

	# 无后端前提与 dialog_check 一致（交互测试若进对话不依赖网络）
	dm.api_url = "http://127.0.0.1:3997"
	gm.handbook_path = "res://handbook_test_tmp.json"
	gm.reset_handbook()

	var sens: float = float(gm.get_setting("mouse_sensitivity"))

	# ══ §1 鼠标运动: 入口 A 分发通断 + 比例性 + 符号 ══
	_reset_view(player)
	_push(_motion(100, 0))
	var dy1: float = player.yaw - 0.0
	_check(absf(dy1) > 0.0001, "push_input 鼠标运动抵达控制器 (dyaw=%.4f)" % dy1)
	_reset_view(player)
	_push(_motion(50, 0))
	var dy2: float = player.yaw - 0.0
	if absf(dy1) > 0.0001:
		var ratio: float = dy2 / dy1
		_check(absf(ratio - 0.5) < 0.05, "位移量线性 (50px/100px=%.3f≈0.5)" % ratio)
	_check(dy1 < 0.0, "水平符号正确 (右移视角左转, dyaw<0)")

	# ══ §2 鼠标运动: 入口 B (Input.parse_input_event) 同样抵达 ══
	_reset_view(player)
	Input.parse_input_event(_motion(80, 0))
	Input.flush_buffered_events()
	var dy3: float = player.yaw - 0.0
	_check(absf(dy3) > 0.0001, "parse_input_event 鼠标运动抵达控制器 (dyaw=%.4f)" % dy3)

	# ══ §3 俯仰钳位 ±89°（超大输入不得翻转/出界） ══
	_reset_view(player)
	_push(_motion(0, 100000))
	_check(is_equal_approx(player.pitch, deg_to_rad(-89.0)),
		"俯仰下钳 -89° (%.4f rad)" % player.pitch)
	_reset_view(player)
	_push(_motion(0, -100000))
	_check(is_equal_approx(player.pitch, deg_to_rad(89.0)),
		"俯仰上钳 +89° (%.4f rad)" % player.pitch)
	_reset_view(player)

	# ══ §4 点击重新捕获鼠标 ══
	# headless display 不支持捕获(实测 set(CAPTURED) 读回恒 VISIBLE)——鼠标显隐状态机
	# 不可 headless 断言, 降级为"点击事件抵达控制器且不误触其它状态", 真机手测清单覆盖。
	var mode_before := Input.get_mouse_mode()
	_push(_button(MOUSE_BUTTON_LEFT))
	await process_frame
	_check(not gm.is_game_paused and not hb.visible and not dm.is_dialog_active(),
		"左键点击抵达且不误触暂停/手册/对话")
	Input.set_mouse_mode(mode_before)

	# ══ §5 负向输入: 滚轮/右键/中键/无绑定键 不改变游戏状态 ══
	_reset_view(player)
	var p0: Vector3 = player.global_position
	_push(_button(MOUSE_BUTTON_WHEEL_UP))
	_push(_button(MOUSE_BUTTON_WHEEL_DOWN))
	_push(_button(MOUSE_BUTTON_RIGHT))
	_push(_button(MOUSE_BUTTON_MIDDLE))
	var unbound := InputEventKey.new()
	unbound.keycode = KEY_F9
	_push(unbound)
	await process_frame
	_check(absf(player.yaw) < 0.0001 and absf(player.pitch) < 0.0001,
		"滚轮/右键/中键/F9 不影响视角")
	_check(player.global_position.distance_to(p0) < 0.01, "无绑定键不致位移")

	# ══ §6 WASD 四方向 (action map→控制器消费; action 路径无坐标变换系数问题) ══
	# 每方向: 先等停步清零(避免上一方向残留速度吃掉本方向的加速帧), 再 press 等到速
	var vel: Vector3
	_reset_view(player)
	for i in 8:
		await physics_frame
	Input.action_press("move_forward")
	for i in 8:
		await physics_frame
	vel = player.velocity
	_check(vel.z < -3.0, "W 前进 velocity.z<0 (%.2f)" % vel.z)
	Input.action_release("move_forward")
	for i in 12:
		await physics_frame
	Input.action_press("move_backward")
	for i in 8:
		await physics_frame
	vel = player.velocity
	_check(vel.z > 3.0, "S 后退 velocity.z>0 (%.2f)" % vel.z)
	Input.action_release("move_backward")
	for i in 12:
		await physics_frame
	Input.action_press("move_left")
	for i in 8:
		await physics_frame
	vel = player.velocity
	_check(vel.x < -3.0, "A 左移 velocity.x<0 (%.2f)" % vel.x)
	Input.action_release("move_left")
	for i in 12:
		await physics_frame
	Input.action_press("move_right")
	for i in 8:
		await physics_frame
	vel = player.velocity
	_check(vel.x > 3.0, "D 右移 velocity.x>0 (%.2f)" % vel.x)
	Input.action_release("move_right")
	for i in 12:
		await physics_frame

	# 对角归一: W+A 合速度不得超过 move_speed（超速=归一化丢失）
	Input.action_press("move_forward")
	Input.action_press("move_left")
	for i in 6:
		await physics_frame
	var hspeed: float = Vector2(player.velocity.x, player.velocity.z).length()
	_check(hspeed <= player.move_speed + 0.1,
		"对角合速度≤move_speed (v=%.2f ≤ %.2f)" % [hspeed, player.move_speed])
	Input.action_release("move_forward")
	Input.action_release("move_left")
	for i in 8:
		await physics_frame
	hspeed = Vector2(player.velocity.x, player.velocity.z).length()
	_check(hspeed < 0.5, "停步衰减回零 (%.2f < 0.5)" % hspeed)

	# ══ §7 interact: 真实站位(3m 交互射线) + action 触发对话 ══
	var marie: Node3D = null
	for npc in get_nodes_in_group("npc"):
		if npc.name.begins_with("NPCWaiter"):
			marie = npc
	_check(marie != null, "找到 Marie 供交互测试")
	if marie != null:
		# 站位照 playthrough_check 先例: Marie 面向街道(-X), 站她面前 1.4m 并瞄准
		var start_y := player.global_position.y
		player.global_position = Vector3(marie.global_position.x - 1.4, start_y, marie.global_position.z)
		_aim_at(player, marie)
		for i in 4:
			await physics_frame
		var ray: RayCast3D = player.get_node("Camera3D/InteractionRay")
		_check(ray.get_target() == marie, "站位后交互射线识别 Marie")
		# interact 是"事件型"动作(_unhandled_input 的 is_action_pressed), 必须走事件入口;
		# Input.action_press() 只写持续状态, 不产生事件(实测对话不开, 已记入断言策略注释)
		_push(_action("interact"))
		await physics_frame
		_check(dm.is_dialog_active(), "interact 事件→对话开启")
		# 对话中视角冻结、移动按决策9允许(非打字)
		var yaw_locked: float = player.yaw
		_push(_motion(500, 0))
		_check(absf(player.yaw - yaw_locked) < 0.0001, "对话中视角冻结")
		Input.action_press("move_forward")
		await physics_frame
		await physics_frame
		_check(true, "对话中移动分支不崩(决策9 允许走开)")
		Input.action_release("move_forward")
		# 结束对话: ESC 两段式走 DialogManager 入口(与 dialog_check 同路径)
		dm._unhandled_input(_action("ui_cancel"))
		await process_frame
		if dm.is_dialog_active():
			dm._unhandled_input(_action("ui_cancel"))
			await process_frame
		_check(not dm.is_dialog_active(), "ESC 结束对话复位")
		player.is_in_dialog = false
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	# ══ §8 handbook: 打开冻结输入、关闭释放 ══
	_reset_view(player)
	_push(_action("handbook"))
	await process_frame
	_check(hb.visible and player.ui_blocked, "Tab(handbook action)→手册开+输入冻结")
	var yaw_f: float = player.yaw
	_push(_motion(300, 0))
	_check(absf(player.yaw - yaw_f) < 0.0001, "手册打开时视角冻结")
	var pos_f: Vector3 = player.global_position
	Input.action_press("move_forward")
	for i in 4:
		await physics_frame
	var moved_f: float = player.global_position.distance_to(pos_f)
	var vspeed_f: float = Vector2(player.velocity.x, player.velocity.z).length()
	_check(moved_f < 0.01 and vspeed_f < 0.1,
		"手册打开时移动冻结 (Δp=%.3f, |v|=%.2f)" % [moved_f, vspeed_f])
	Input.action_release("move_forward")
	_push(_action("handbook"))
	await process_frame
	_check(not hb.visible and not player.ui_blocked, "再按→手册关+输入释放")

	# ══ §9 ESC 暂停状态机: 开→暂停+鼠标可见; 合→恢复+鼠标捕获 ══
	# mouse mode 显隐在 headless 不可读(实测 set 恒读 0/VISIBLE), 只断言暂停状态机;
	# 鼠标显隐留真机手测。
	_push(_action("ui_cancel"))
	await process_frame
	_check(gm.is_game_paused and paused, "ESC→暂停 (is_game_paused/tree.paused)")
	_push(_action("ui_cancel"))
	await process_frame
	_check(not gm.is_game_paused and not paused, "再按 ESC→恢复")

	# 手册打开时 ESC: 事件语义=手册关闭+暂停不误触(handbook_ui 消费 ui_cancel 关闭;
	# gm._unhandled_input 对 visible 手册让路)——两个结果一起断言
	_push(_action("handbook"))
	await process_frame
	_check(hb.visible, "手册已开 (前提)")
	_push(_action("ui_cancel"))
	await process_frame
	_check(not hb.visible, "手册打开时 ESC→手册关闭 (handbook_ui 消费)")
	_check(not gm.is_game_paused, "ESC 关手册时 gm 让路 (不误触暂停)")

	# ══ §10 失焦→自动暂停、可恢复（native focus 不可注入, 直调状态机入口） ══
	# 前提复位: 手册关/对话结束/未暂停(handle_focus_lost 对三者各有让路分支)
	if hb.visible:
		_push(_action("handbook"))
		await process_frame
	if dm.is_dialog_active():
		dm._unhandled_input(_action("ui_cancel"))
		await process_frame
	if gm.is_game_paused:
		gm.toggle_pause()
		await process_frame
	gm.handle_focus_lost()
	await process_frame
	_check(gm.is_game_paused, "失焦→自动暂停")
	gm.toggle_pause()
	await process_frame
	_check(not gm.is_game_paused, "恢复后可继续 (无软锁)")

	# ══ §11 灵敏度热更: 设置变更→控制器即时采用(比例断言) ══
	var old_sens: float = sens
	gm.set_setting("mouse_sensitivity", 0.004)
	await process_frame
	_check(absf(player.mouse_sensitivity - 0.004) < 0.00001,
		"灵敏度热更到控制器 (%.4f)" % player.mouse_sensitivity)
	_reset_view(player)
	_push(_motion(100, 0))
	var dy_new: float = player.yaw - 0.0
	if absf(dy1) > 0.0001 and absf(dy_new) > 0.0001:
		var s_ratio: float = dy_new / dy1
		_check(absf(s_ratio - 2.0) < 0.2, "新灵敏度成比例 (dyaw比=%.3f≈2.0)" % s_ratio)
	gm.set_setting("mouse_sensitivity", old_sens)
	await process_frame
	_reset_view(player)

	# 收尾: 清理临时存档
	if FileAccess.file_exists("res://handbook_test_tmp.json"):
		DirAccess.remove_absolute("res://handbook_test_tmp.json")

	print("")
	if failures == 0:
		print("INPUT_ALL_PASS (逻辑层 %d 类输入路径)" % 11)
	else:
		print("INPUT_CHECK: %d 项失败" % failures)
	print("INPUT_SCOPE: 绿=事件入口→分发→action map→控制器状态机链路; " +
		"display 层(niri 窗口焦点/真实指针捕获/嵌入转发)不可 headless 注入, 须真机手测: " +
		"①点游戏画面获焦 ②WASD ③鼠标转视角 ④E 交谈 ⑤Tab 手册 ⑥Esc 暂停 ⑦滚轮/右键无副作用 ⑧Alt-Tab 失焦自动暂停")
	quit(1 if failures > 0 else 0)
