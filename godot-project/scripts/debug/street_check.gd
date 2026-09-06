extends SceneTree

## 结构自检脚本 (headless) — 验证街景 + 咖啡馆 + NPC 与布局一致
## 用法: godot --headless --path godot-project -s res://scripts/debug/street_check.gd

var failures: int = 0

func _init():
	_run()

func _run():
	var scene: PackedScene = load("res://scenes/main.tscn")
	var main: Node = scene.instantiate()
	root.add_child(main)
	await process_frame
	await process_frame
	await process_frame

	var gen: Node = main.get_node_or_null("StreetGenerator")
	_check(gen != null, "StreetGenerator 存在")
	if gen == null:
		_quit()
		return

	var layout: Dictionary = gen.layout
	var layout_buildings: Array = layout.get("buildings", [])
	var cafe_buildings := 0
	for b in layout_buildings:
		if b.get("is_cafe", false):
			cafe_buildings += 1
	var expected: int = layout_buildings.size() - cafe_buildings

	# 统计生成的建筑(排除 cafe 占位与清除区)
	var bld_root: Node = gen.buildings_root
	var gen_buildings := 0
	var cafe_zone_skipped := 0
	if bld_root:
		for child in bld_root.get_children():
			if child.name.begins_with("Building_"):
				gen_buildings += 1
			elif child.name == "CafeSite":
				pass
	# 生成器按清除区跳过同侧邻近建筑: 期望数 = 布局数 - cafe - 清除区被跳过的
	# 验证数量 > 0 且大致合理(咖啡馆±6m同侧被清除, 故 <= 布局非cafe数)
	_check(gen_buildings > 0, "生成建筑数: %d" % gen_buildings)
	_check(gen_buildings <= expected, "生成建筑不超布局(实际 %d <= %d)" % [gen_buildings, expected])

	# 咖啡馆
	var cafe_site: Node = gen.cafe_site
	_check(cafe_site != null, "CafeSite 存在")
	if cafe_site:
		_check(cafe_site.get_node_or_null("CafeModel") != null, "咖啡馆 glb 已实例化")
		var col := cafe_site.get_node_or_null("CafeCollision")
		_check(col != null, "咖啡馆碰撞体存在")
		if col:
			var n_shapes: int = col.get_child_count()
			_check(n_shapes >= 6, "碰撞盒数量合理 (%d)" % n_shapes)

	# NPC
	var npcs := get_nodes_in_group("npc")
	_check(npcs.size() == 3, "3 个 NPC 已生成(实际 %d)" % npcs.size())
	for npc in npcs:
		_check(npc.global_position.y >= 0.0, "%s 在地面上 y=%.2f" % [npc.name, npc.global_position.y])

	# 玩家
	var player: Node = main.get_node_or_null("Player")
	_check(player != null, "玩家存在")

	# 每个建筑碰撞
	var no_col := 0
	if bld_root:
		for child in bld_root.get_children():
			if not child.name.begins_with("Building_"):
				continue
			var has_col := false
			for c in child.get_children():
				if c is CollisionShape3D:
					has_col = true
			if not has_col:
				no_col += 1
	_check(no_col == 0, "所有建筑有碰撞体(缺失 %d)" % no_col)

	# 面数估算
	var total_faces := 0
	if bld_root:
		for child in bld_root.get_children():
			for mesh_node in _collect_mesh(child):
				total_faces += _mesh_faces(mesh_node)
	print("[StreetCheck] 建筑估算面数: ", total_faces)
	_check(total_faces < 50000, "建筑面数预算(实际 %d)" % total_faces)

	main.queue_free()
	_quit()

func _collect_mesh(node: Node, acc: Array = []) -> Array:
	if node is MeshInstance3D:
		acc.append(node)
	for c in node.get_children():
		_collect_mesh(c, acc)
	return acc

func _mesh_faces(mi: MeshInstance3D) -> int:
	var m: Mesh = mi.mesh
	if m == null:
		return 0
	if m is BoxMesh:
		return 12
	if m is PlaneMesh:
		return 2
	var arrs = m.surface_get_arrays(0)
	if arrs.is_empty() or arrs[Mesh.ARRAY_INDEX] == null:
		return 0
	return int(arrs[Mesh.ARRAY_INDEX].size() / 3)

func _check(cond: bool, msg: String):
	if cond:
		print("[OK] ", msg)
	else:
		failures += 1
		print("[FAIL] ", msg)

func _quit():
	print("[StreetCheck] 失败数: ", failures)
	quit(failures)
