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
]

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
	for shot in _shots:
		var cam_pos: Vector3 = shot[1]
		var look: Vector3 = shot[2]
		_place_camera(main, cam_pos, look)
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
