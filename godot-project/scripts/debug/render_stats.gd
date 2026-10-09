extends SceneTree

## 渲染统计探针（优化取证用）— 带显示运行（llvmpipe 软渲染亦可），
## 输出 draw call / 图元 / 对象数 / 节点规模，供"优化前 vs 优化后"相对对比。
##
## 用法（基线/复测）:
##   XDG_DATA_HOME=$PWD/.userdata LIBGL_ALWAYS_SOFTWARE=1 \
##   ./tools/Godot_v4.7.2-stable_linux.x86_64 --rendering-driver opengl3 \
##   --path godot-project -s res://scripts/debug/render_stats.gd
##
## 用法（归因诊断: 逐项开关看 draw call 变化）:
##   ... 同上 + 环境变量 LV_RS_DIAG=1
##
## scope: llvmpipe 软渲染下 **仅作相对对比**（同一环境前后各跑一次看差值），
##        不代表真机 GPU 的绝对帧率；draw call 为渲染器提交次数，与 GPU 快慢无关。

const VIEWS := [
	["spawn_street", Vector3(0, 1.7, -18), Vector3(3, 1.6, 20)],
	["cafe_front", Vector3(-1.0, 1.7, 4.34), Vector3(6, 2.2, 4.34)],
]

func _init():
	_run()

func _run() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn")
	var main: Node = scene.instantiate()
	root.add_child(main)
	for i in 10:
		await process_frame

	var counts := _count_types(main)
	print("STATS nodes_total=", _count_nodes(main))
	for k in counts.keys():
		print("STATS type_%s=%d" % [k, counts[k]])

	for view in VIEWS:
		_place_camera(main, view[1], view[2])
		for i in 6:
			await process_frame
		await process_frame
		print("VIEW %s draw_calls=%d objects=%d primitives=%d" % [
			view[0],
			int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
			int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
			int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		])
	print("STATS video_mem_mb=%.1f" % (
		Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0))

	if OS.get_environment("LV_RS_DIAG") == "1":
		await _diagnose(main)
	print("RENDER_STATS_DONE")
	quit(0)

## 归因诊断：一次只开一项，量完立刻还原（每项相对同一机位的 baseline）
func _diagnose(main: Node) -> void:
	_place_camera(main, VIEWS[0][1], VIEWS[0][2])
	for i in 6:
		await process_frame
	var base := _dc()
	print("DIAG baseline draw_calls=%d" % base)

	# 1) 太阳阴影关掉 → 阴影通道占比
	var sun: Node3D = main.get_node_or_null("Sun")
	if sun and sun is Light3D:
		var l: Light3D = sun
		l.shadow_enabled = false
		await _measure("sun_shadow_off", base)
		l.shadow_enabled = true

	# 2) 隐藏全部 Detail_* （立面细节） → 细节占比
	var hidden: Array = []
	for n in _walk(main):
		if n is MeshInstance3D and String(n.name).begins_with("Detail_"):
			n.visible = false
			hidden.append(n)
	await _measure("hide_details", base)
	for n in hidden:
		n.visible = true

	# 3) 隐藏 StreetProps（树/灯/椅/围栏等街道家具）
	var props := _find(main, "StreetProps")
	var props_nodes: Array = []
	if props:
		for n in _walk(props):
			if n is MeshInstance3D or n is Label3D:
				n.visible = false
				props_nodes.append(n)
	await _measure("hide_street_props", base)
	for n in props_nodes:
		n.visible = true

	# 4) 隐藏全部 Label3D（名牌/路名/铭牌）
	var labels: Array = []
	for n in _walk(main):
		if n is Label3D:
			n.visible = false
			labels.append(n)
	await _measure("hide_labels", base)
	for n in labels:
		n.visible = true

	# 5) 隐藏全部 OmniLight3D（路灯夜灯）
	var lights: Array = []
	for n in _walk(main):
		if n is OmniLight3D:
			n.visible = false
			lights.append(n)
	await _measure("hide_omni_lights", base)
	for n in lights:
		n.visible = true

	# 6) 隐藏建筑本体（Wall/Roof/Facade 之外全算建筑侧）
	var bmeshes: Array = []
	for n in _walk(main):
		if n is MeshInstance3D and _has_ancestor_named(n, "Building_"):
			n.visible = false
			bmeshes.append(n)
	await _measure("hide_all_building_meshes", base)
	for n in bmeshes:
		n.visible = true

func _has_ancestor_named(n: Node, prefix: String) -> bool:
	var p := n.get_parent()
	while p:
		if String(p.name).begins_with(prefix):
			return true
		p = p.get_parent()
	return false

func _dc() -> int:
	return int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))

func _measure(label: String, base: int) -> void:
	for i in 6:
		await process_frame
	await process_frame
	var v := _dc()
	print("DIAG %s draw_calls=%d delta=%+d" % [label, v, v - base])

func _count_nodes(n: Node, acc: int = 0) -> int:
	var c := acc + 1
	for ch in n.get_children():
		c = _count_nodes(ch, c)
	return c

func _count_types(n: Node, acc: Dictionary = {}) -> Dictionary:
	var t := n.get_class()
	acc[t] = int(acc.get(t, 0)) + 1
	for ch in n.get_children():
		_count_types(ch, acc)
	return acc

func _walk(n: Node, out: Array = []) -> Array:
	out.append(n)
	for c in n.get_children():
		_walk(c, out)
	return out

func _find(n: Node, want: String) -> Node:
	if String(n.name) == want:
		return n
	for c in n.get_children():
		var r := _find(c, want)
		if r != null:
			return r
	return null

func _place_camera(main: Node, cam_pos: Vector3, look_at: Vector3) -> void:
	var player: Node3D = main.get_node_or_null("Player")
	if player == null:
		return
	var cam: Camera3D = player.get_node_or_null("Camera3D")
	player.global_position = cam_pos
	player.rotation = Vector3.ZERO
	if cam:
		cam.look_at(look_at, Vector3.UP)
