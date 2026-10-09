extends SceneTree

## 距离剔除细节的收益预估（归因诊断，审计用）— 量完还原。
## 用法: XDG_DATA_HOME=$PWD/.userdata LIBGL_ALWAYS_SOFTWARE=1 \
##   ./tools/Godot_v4.7.2-stable_linux.x86_64 --rendering-driver opengl3 \
##   --path godot-project -s res://scripts/debug/detail_lod_diag.gd

const VIEW_POS := Vector3(0, 1.7, -18)
const VIEW_LOOK := Vector3(3, 1.6, 20)

func _init():
	_run()

func _run() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn")
	var main: Node = scene.instantiate()
	root.add_child(main)
	for i in 10:
		await process_frame
	_place_camera(main)
	for i in 6:
		await process_frame
	var base := _dc()
	print("DIAG baseline draw_calls=%d objects=%d" % [
		base, int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))])

	var details: Array = []
	for n in _walk(main):
		if n is MeshInstance3D and String(n.name).begins_with("Detail_"):
			details.append(n)
	print("DIAG detail_nodes_total=%d" % details.size())

	for dist in [25.0, 40.0, 60.0]:
		var hidden := 0
		for n in details:
			if n.global_position.distance_to(VIEW_POS) > dist:
				n.visible = false
				hidden += 1
		for i in 6:
			await process_frame
		await process_frame
		print("DIAG hide_details_beyond_%dm draw_calls=%d delta=%+d hidden=%d" % [
			int(dist), _dc(), _dc() - base, hidden])
		for n in details:
			n.visible = true

	print("DETAIL_LOD_DIAG_DONE")
	quit(0)

func _dc() -> int:
	return int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))

func _walk(n: Node, out: Array = []) -> Array:
	out.append(n)
	for c in n.get_children():
		_walk(c, out)
	return out

func _place_camera(main: Node) -> void:
	var player: Node3D = main.get_node_or_null("Player")
	if player == null:
		return
	var cam: Camera3D = player.get_node_or_null("Camera3D")
	player.global_position = VIEW_POS
	player.rotation = Vector3.ZERO
	if cam:
		cam.look_at(VIEW_LOOK, Vector3.UP)
