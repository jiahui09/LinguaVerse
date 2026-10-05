extends SceneTree

## 截图脚本（操作逻辑 P2）— E 提示/键位条 + 新居民手册三分页
## 用途：llvmpipe 软渲染下的**位置抽查**（元素是否在预期位置、内容是否渲染出来），
##       不构成视觉验收（本机无 GPU，见 docs/项目进度.md §三 #5）。
## 用法(沙箱llvmpipe软渲染):
##   mkdir -p .userdata && XDG_DATA_HOME=$PWD/.userdata LIBGL_ALWAYS_SOFTWARE=1 \
##     ./tools/Godot_v4.7.2-stable_linux.x86_64 --rendering-driver opengl3 \
##     --path godot-project -s res://scripts/debug/handbook_capture.gd

func _init():
	_run()

func _run():
	DirAccess.make_dir_recursive_absolute("res://screenshots")
	var scene: PackedScene = load("res://scenes/main.tscn")
	var main: Node = scene.instantiate()
	root.add_child(main)
	for i in 6:
		await process_frame

	var viewport := root
	var player: Node3D = main.get_node("Player")
	var gm: Node = root.get_node_or_null("GameManager")
	var hud: Node = main.get_node("HudHints")
	var hb: Node = main.get_node("Handbook")
	var marie: Node3D = null
	for npc in get_nodes_in_group("npc"):
		if npc.name.begins_with("NPCWaiter"):
			marie = npc

	# 存档写到项目内临时文件（headless 沙箱 user:// 不可写），结束清理
	if gm:
		gm.handbook_path = "res://handbook_shot_tmp.json"
		gm.reset_handbook()

	# ── shot 06：真实射线路径下的 E 提示 + 底部键位条 ──
	if marie:
		player.global_position = Vector3(marie.global_position.x - 1.4, player.global_position.y,
			marie.global_position.z)
		_aim_at(player, marie)
		for i in 6:
			await physics_frame
	await process_frame
	await process_frame
	_save(viewport, "shot_06_hint_quicktips")

	# ── 手册数据播种（用记录 API 产生内容，展示层只读取；非真实游玩累积） ──
	if gm:
		gm.record_zone("street_north")
		gm.record_zone("cafe")
		gm.record_daypart("dawn")
		gm.record_daypart("dusk")
		gm.record_npc_met({"name": "Marie", "job": "咖啡馆服务员"})
		gm.record_npc_met({"name": "Marie", "job": "咖啡馆服务员"})
		gm.record_npc_met({"name": "Jean", "job": "退休老人"})
		gm.record_phrase("un café, s'il vous plaît", "Marie")
		gm.record_phrase("Bonjour, je viens de m'installer ici.", "Jean")

	# ── shot 07/08/09：手册三分页 ──
	hb.open()
	hb.open_tab(0)
	await process_frame
	await process_frame
	_save(viewport, "shot_07_handbook_traces")

	hb.open_tab(1)
	await process_frame
	_save(viewport, "shot_08_handbook_voisins")

	hb.open_tab(2)
	await process_frame
	_save(viewport, "shot_09_handbook_paroles")

	hb.close()
	if gm and FileAccess.file_exists("res://handbook_shot_tmp.json"):
		DirAccess.remove_absolute(ProjectSettings.globalize_path("res://handbook_shot_tmp.json"))
	print("HANDBOOK_SHOTS_ALL_DONE")
	main.queue_free()
	quit(0)

func _save(viewport: Viewport, name: String):
	var img: Image = viewport.get_texture().get_image()
	var path: String = "res://screenshots/" + name + ".png"
	img.save_png(path)
	print("SHOT_SAVED: ", path)

## 玩家视线对准 NPC（与 playthrough_check._aim_at 同口径）
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
