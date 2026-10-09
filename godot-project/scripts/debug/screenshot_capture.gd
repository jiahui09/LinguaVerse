extends SceneTree

## 截图脚本 — 渲染主要视角并保存 PNG
## 用法(真实GPU):
##   ./tools/Godot_v4.7.2-stable_linux.x86_64 --path godot-project -s res://scripts/debug/screenshot_capture.gd
## 用法(沙箱llvmpipe软渲染):
##   mkdir -p .userdata && XDG_DATA_HOME=$PWD/.userdata LIBGL_ALWAYS_SOFTWARE=1 \
##     ./tools/Godot_v4.7.2-stable_linux.x86_64 --rendering-driver opengl3 \
##     --path godot-project -s res://scripts/debug/screenshot_capture.gd

var _shots: Array = [
	["shot_01_player_view", Vector3(0, 1.7, -18), Vector3(3, 1.6, 20)],   # 玩家视角望咖啡馆
	["shot_02_facade_left", Vector3(-3.0, 1.7, -2), Vector3(-20, 6, 10)],  # 左立面
	["shot_03_facade_right", Vector3(3.0, 1.7, -2), Vector3(20, 6, 10)],   # 右立面
	["shot_04_cafe_front", Vector3(-1.0, 1.7, 4.34), Vector3(6, 2.2, 4.34)],  # 咖啡馆正面
	["shot_05_street_end", Vector3(0, 2.5, 30), Vector3(0, 1.4, -15)],     # 街尾回望
	["shot_06_natural_end", Vector3(0, 2.6, 76), Vector3(0, 1.0, 90.5)],   # P3-5 自然端: 花坛×3+护柱×4
	["shot_07_hydrant_end", Vector3(0, 2.0, -58), Vector3(4.78, 0.6, -72)],# P3-5 街端消防栓 + 树池篦
]

func _init():
	_run()

func _run():
	DirAccess.make_dir_recursive_absolute("res://screenshots")
	# 取证环境: 断开窗口失焦自动暂停 (llvmpipe 无焦点窗口启动即失焦 → 设置面板挡镜头,
	# 批次4 已记"截图时面板弹出, 取证需知")。只断本截图进程, 游戏内行为不变。
	# 若失焦已在引擎启动时触发过 (已暂停+面板可见) → 恢复暂停 + 每张前再藏一次面板。
	var win := root  # SceneTree 的 root 即 Window (焦点信号宿主)
	var gm: Node = root.get_node_or_null("GameManager")
	if win != null and gm != null and win.focus_exited.is_connected(gm._on_focus_exited):
		win.focus_exited.disconnect(gm._on_focus_exited)
	if gm != null and gm.get("is_game_paused") == true:
		gm.call("toggle_pause")
	# 取证期间强制世界运行：两侧代码的"初次失焦是否已暂停/恢复"时序不同，
	# 若一侧世界被冻结（玩家不落地、NPC 不推进），同机位也会出现 ~40 的假差异。
	# 每帧强制 paused=false + 藏面板 → 两侧都按"运行中世界"收敛，结果才可比。
	paused = false
	var scene: PackedScene = load("res://scenes/main.tscn")
	var main: Node = scene.instantiate()
	root.add_child(main)
	for i in 6:
		await process_frame

	var viewport := root
	# P3 批次7: 拱廊机位运行时校准 (手推世界坐标不可信 — vosges 根带 -155° 旋转)
	var lm: Node3D = _find_by_name(main, "Landmark_place_des_vosges")
	if lm != null:
		var lp: Vector3 = lm.global_position
		var nrm: Vector3 = lm.global_transform.basis.x.normalized()   # 朝街 (+X local)
		var fwd: Vector3 = lm.global_transform.basis.z.normalized()   # 沿街
		# 近景: 街对面 9m 平视拱廊中段 (沿街偏 4m 避开前景路灯)
		_shots.append(["shot_08_arcade_close",
			lp + nrm * 9.0 + fwd * 4.0 + Vector3(0, 2.4, 0),
			lp + fwd * 3.5 + Vector3(0, 4.2, 0)])
		# 全景: 街心退到空档外 34m 高位 (避开对面树列树冠)
		_shots.append(["shot_09_arcade_wide",
			lp + nrm * 11.0 - fwd * 34.0 + Vector3(0, 4.5, 0),
			lp + Vector3(0, 4.5, 0)])
	else:
		print("SHOT_SKIP: Landmark_place_des_vosges 未找到 (shot_08/09 缺席)")

	# P3 批次8: NPC 外观模型近景（决策 27 模型化弃球眼的目检取证; spawner 已 spawn 完）
	for npc in get_nodes_in_group("npc"):
		var nn := String(npc.name)
		var prefix := ""
		var dist := 3.0
		var side_off := 0.0
		if nn.begins_with("NPCWaiter"):
			prefix = "shot_10_marie_model"
			# 吧台面高道具(咖啡机组)从正面全挡员工 — 本机位临时把 Marie 移到街心空地
			# 拍全身取证 (仅截图进程内存, 不落盘; 游戏内站位不变)
			npc.global_position = Vector3(9.0, 0.0, -14.0)
			dist = 3.0
			side_off = 0.0
		elif nn.begins_with("NPCResident_Colette"):
			prefix = "shot_11_resident_model"
		elif nn.begins_with("NPCPedestrian"):
			prefix = "shot_12_pierre_walk"   # WALK 中: 程序摆动的步态取证
			dist = 4.5   # 行人会漂移, 留余量
		if prefix == "":
			continue
		var np_: Vector3 = npc.global_position
		var nfwd: Vector3 = -npc.global_transform.basis.z.normalized()   # NPC 面向 = 前方
		var nside: Vector3 = Vector3(-nfwd.z, 0.0, nfwd.x)               # 前向绕 Y +90°
		if nn.begins_with("NPCWaiter"):
			np_ = npc.global_position   # 已临时移位, 重取
		_shots.append([prefix,
			np_ + nfwd * dist + nside * side_off + Vector3(0, 1.55, 0),
			np_ + Vector3(0, 1.0, 0)])

	for shot in _shots:
		var cam_pos: Vector3 = shot[1]
		var look: Vector3 = shot[2]
		print("SHOT_POS %s cam=%v look=%v" % [shot[0], cam_pos, look])
		_place_camera(main, cam_pos, look)
		# 失焦自动暂停会弹设置面板挡镜头 (llvmpipe 无焦点窗口, 设计内)。
		# 不注入按键 (ESC 是 toggle, 开/关时序受焦点事件到达时刻影响, 不确定);
		# 直接调 hide_panel() — 面板只是 CanvasItem, 隐藏即可; 暂停态照常渲染。
		for p in get_nodes_in_group("settings_panel"):
			p.call("hide_panel")
		# 定机位后必须等**落地/阴影重算收敛**再截：原实现只等 2 帧，路面亮度
		# 抓在过渡段（_shadow_probe 实测 6~14 帧波动 33~45，第 15 帧起恒定 43.56），
		# 导致同机位跨版本对比出现 ±17% 的假差异。等 16 帧后再截取稳定帧。
		for i in range(16):
			await process_frame
			paused = false
			if i % 4 == 0:
				for p in get_nodes_in_group("settings_panel"):
					p.call("hide_panel")
		var img: Image = viewport.get_texture().get_image()
		var path: String = "res://screenshots/" + shot[0] + ".png"
		img.save_png(path)
		print("SHOT_SAVED: ", path)

	print("SCREENSHOT_ALL_DONE")
	main.queue_free()
	quit(0)

func _find_by_name(n: Node, want: String) -> Node:
	if String(n.name) == want:
		return n
	for c in n.get_children():
		var r := _find_by_name(c, want)
		if r != null:
			return r
	return null

func _place_camera(main: Node, cam_pos: Vector3, look_at: Vector3):
	var player: Node3D = main.get_node_or_null("Player")
	var cam: Camera3D = null
	if player:
		cam = player.get_node_or_null("Camera3D")
	if player:
		player.global_position = cam_pos
	if cam:
		player.rotation = Vector3.ZERO
		cam.look_at(look_at, Vector3.UP)
