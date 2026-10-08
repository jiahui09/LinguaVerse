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
	var scene: PackedScene = load("res://scenes/main.tscn")
	var main: Node = scene.instantiate()
	root.add_child(main)
	for i in 6:
		await process_frame

	var viewport := root
	for shot in _shots:
		var cam_pos: Vector3 = shot[1]
		var look: Vector3 = shot[2]
		_place_camera(main, cam_pos, look)
		# 失焦自动暂停会弹设置面板挡镜头 (llvmpipe 无焦点窗口, 设计内)。
		# 不注入按键 (ESC 是 toggle, 开/关时序受焦点事件到达时刻影响, 不确定);
		# 直接调 hide_panel() — 面板只是 CanvasItem, 隐藏即可; 暂停态照常渲染。
		for p in get_nodes_in_group("settings_panel"):
			p.call("hide_panel")
		await process_frame
		await process_frame
		var img: Image = viewport.get_texture().get_image()
		var path: String = "res://screenshots/" + shot[0] + ".png"
		img.save_png(path)
		print("SHOT_SAVED: ", path)

	print("SCREENSHOT_ALL_DONE")
	main.queue_free()
	quit(0)

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
