extends SceneTree

## 阴影通道归因诊断（优化取证）— 逐项开关，量完还原，同一机位对比。
## 用法: XDG_DATA_HOME=$PWD/.userdata LIBGL_ALWAYS_SOFTWARE=1 \
##   ./tools/Godot_v4.7.2-stable_linux.x86_64 --rendering-driver opengl3 \
##   --path godot-project -s res://scripts/debug/shadow_diag.gd
## scope: llvmpipe 相对对比，不声称真机帧率。

const MAX_DIST_DEFAULT := 100.0   # Godot 默认 directional_shadow_max_distance
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

	var sun: Light3D = main.get_node_or_null("Sun") as Light3D
	_sun_ref = sun
	var all_meshes: Array = []
	for n in _walk(main):
		if n is MeshInstance3D:
			all_meshes.append(n)

	# 1) Detail_* 不投影
	var touched := _set_cast_shadow(all_meshes, func(n: Node): return String(n.name).begins_with("Detail_"), false)
	await _measure("detail_no_shadow", base)
	_restore(touched)

	# 2) 微小件不投影（最大边 < 0.5m 的网格，含路缘/井盖/篦子/小道具）
	touched = _set_cast_shadow(all_meshes, func(n: Node):
		var mi := n as MeshInstance3D
		var b := mi.get_aabb().size
		return maxf(b.x, maxf(b.y, b.z)) < 0.5, false)
	await _measure("tiny_no_shadow(<0.5m)", base)
	_restore(touched)

	# 3) 阴影最大距离 45m（远处建筑不再进阴影通道）
	if "directional_shadow_max_distance" in sun:
		sun.directional_shadow_max_distance = 45.0
		await _measure("shadow_max_dist=45", base)
		sun.directional_shadow_max_distance = 60.0
		await _measure("shadow_max_dist=60", base)
		sun.directional_shadow_max_distance = 80.0
		await _measure("shadow_max_dist=80", base)
		sun.directional_shadow_max_distance = MAX_DIST_DEFAULT
	else:
		print("DIAG skip shadow_max_dist (property missing)")

	# 4) 阴影距离淡出（显式给 begin/length，避免默认值语义不明）
	if "distance_fade_enabled" in sun:
		var b0 = sun.get("distance_fade_begin")
		var l0 = sun.get("distance_fade_length")
		var s0 = sun.get("distance_fade_shadow")
		sun.set("distance_fade_begin", 40.0)
		sun.set("distance_fade_length", 40.0)
		sun.set("distance_fade_shadow", 40.0)
		sun.distance_fade_enabled = true
		await _measure("shadow_distance_fade(40+40)", base)
		sun.distance_fade_enabled = false
		sun.set("distance_fade_begin", b0)
		sun.set("distance_fade_length", l0)
		sun.set("distance_fade_shadow", s0)

	# 5) 组合 A: Detail_* 不投影（只关投影，几何与材质不动）
	touched = _set_cast_shadow(all_meshes, func(n: Node):
		return String(n.name).begins_with("Detail_"), false)
	await _measure("COMBO_A detail_no_shadow", base)

	# 5b) 组合 A + 阴影最大距离 60m
	if "directional_shadow_max_distance" in sun:
		sun.directional_shadow_max_distance = 60.0
		await _measure("COMBO_B A+max_dist=60", base)
		sun.directional_shadow_max_distance = 45.0
		await _measure("COMBO_C A+max_dist=45", base)
		sun.directional_shadow_max_distance = MAX_DIST_DEFAULT
	_restore(touched)

	# 6) 阴影整体关闭（对照上界）
	sun.shadow_enabled = false
	await _measure("no_shadow_at_all", base)
	sun.shadow_enabled = true

	print("SHADOW_DIAG_DONE")
	quit(0)

func _set_cast_shadow(meshes: Array, pred: Callable, value: bool) -> Array:
	var touched: Array = []
	for n in meshes:
		if pred.call(n):
			var mi := n as MeshInstance3D
			touched.append([mi, mi.cast_shadow])
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if not value \
				else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	return touched

func _restore(touched: Array) -> void:
	for t in touched:
		(t[0] as MeshInstance3D).cast_shadow = t[1]

func _dc() -> int:
	return int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))

func _measure(label: String, base: int) -> void:
	for i in 6:
		await process_frame
	await process_frame
	print("DIAG %s draw_calls=%d delta=%+d state=%s" % [label, _dc(), _dc() - base, str(_sun_state())])

var _sun_ref: Light3D = null

func _sun_state() -> Dictionary:
	if _sun_ref == null:
		return {}
	return {
		"shadow": _sun_ref.shadow_enabled,
		"max_dist": _sun_ref.get("directional_shadow_max_distance"),
		"fade": _sun_ref.get("distance_fade_enabled"),
		"fade_begin": _sun_ref.get("distance_fade_begin"),
		"fade_len": _sun_ref.get("distance_fade_length"),
		"fade_shadow": _sun_ref.get("distance_fade_shadow"),
	}

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
