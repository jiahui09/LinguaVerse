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

	# ── 街道道具 (P1-4 / 决策 11 自然边界) ──
	var props: Node = null
	if bld_root:
		props = bld_root.get_node_or_null("StreetProps")
	_check(props != null, "StreetProps 存在")
	var n_props := 0
	if props:
		n_props = props.get_child_count()
	_check(n_props >= 10, "StreetProps 子节点 ≥ 10 (实际 %d)" % n_props)

	var n_trees := 0
	var n_lamps := 0
	var n_benches := 0
	var n_barriers := 0
	var barriers: Array = []
	var decor_layer_ok := false
	var lamp_light: OmniLight3D = null
	if props:
		for child in props.get_children():
			var nm := String(child.name)
			if nm.begins_with("Tree_"):
				n_trees += 1
			elif nm.begins_with("Lamp_"):
				n_lamps += 1
				if lamp_light == null:
					for c in child.get_children():
						if c is OmniLight3D:
							lamp_light = c as OmniLight3D
							break
			elif nm.begins_with("Bench_"):
				n_benches += 1
			elif nm.begins_with("Barrier_"):
				n_barriers += 1
				barriers.append(child)
			# 装饰层抽样: 任取一个装饰道具(树/灯/椅)须在 layer 3(值 4)
			if not decor_layer_ok and child is StaticBody3D \
					and (child as StaticBody3D).collision_layer == 4:
				decor_layer_ok = true
	_check(n_trees >= 6, "行道树 ≥ 6 (实际 %d)" % n_trees)
	_check(n_lamps >= 6, "路灯 ≥ 6 (实际 %d)" % n_lamps)
	_check(n_benches >= 2, "长椅 ≥ 2 (实际 %d)" % n_benches)
	_check(n_barriers == 2, "施工围栏 Barrier_* == 2 (实际 %d)" % n_barriers)

	# 围栏须在世界层(1)且带碰撞体
	var barrier_ok := n_barriers == 2
	for bk in barriers:
		var bar := bk as StaticBody3D
		if bar == null or bar.collision_layer != 1:
			barrier_ok = false
			continue
		var has_shape := false
		for c in bar.get_children():
			if c is CollisionShape3D:
				has_shape = true
		if not has_shape:
			barrier_ok = false
	_check(barrier_ok, "每道围栏 collision_layer==1 且有 CollisionShape3D")

	# 路灯夜光: set_night_glow 驱动 OmniLight 能量 (测完恢复 0)
	_check(lamp_light != null, "至少一盏路灯带 OmniLight3D")
	var glow_on_ok := false
	var glow_off_ok := false
	if lamp_light != null and gen.has_method("set_night_glow"):
		gen.set_night_glow(1.0)
		glow_on_ok = lamp_light.light_energy > 0.0
		gen.set_night_glow(0.0)
		glow_off_ok = lamp_light.light_energy == 0.0
		# 已恢复白天基线(0); 昼夜循环每 10 帧会按现实时间重新驱动
	_check(glow_on_ok, "set_night_glow(1.0) → 灯 energy > 0")
	_check(glow_off_ok, "set_night_glow(0.0) → 灯 energy == 0")

	# 装饰道具层(4) + 玩家 mask(1|4=5); NPC mask 仍为 1 → 不撞装饰道具
	_check(decor_layer_ok, "装饰道具 collision_layer == 4")
	var pc := player as CharacterBody3D
	var mask_v := -1
	if pc != null:
		mask_v = pc.collision_mask
	_check(mask_v >= 0 and (mask_v & 5) == 5, "Player collision_mask & 5 == 5 (实际 %d)" % mask_v)

	# ── 昼夜去锁 (决策 7): LV_FIXED_HOUR 为空 → 跟随现实时间 ──
	var sun := main.get_node_or_null("Sun")
	var env_hour := OS.get_environment("LV_FIXED_HOUR")
	if env_hour.is_empty():
		var fh := -2.0
		if sun != null:
			fh = float(sun.get("fixed_hour"))
		_check(fh == -1.0, "未设 LV_FIXED_HOUR → sun.fixed_hour == -1 跟随现实 (实际 %.2f)" % fh)
	else:
		print("[SKIP] LV_FIXED_HOUR=", env_hour, " 已设置 → 跳过 fixed_hour 断言")

	# 面数估算 (buildings_root 全部子节点, 含 StreetProps 道具)
	var total_faces := 0
	if bld_root:
		for child in bld_root.get_children():
			for mesh_node in _collect_mesh(child):
				total_faces += _mesh_faces(mesh_node)
	var prop_faces := 0
	if props:
		for child in props.get_children():
			for mesh_node in _collect_mesh(child):
				prop_faces += _mesh_faces(mesh_node)
	print("[StreetCheck] 建筑估算面数: ", total_faces - prop_faces)
	print("[StreetCheck] 道具估算面数: ", prop_faces)
	_check(total_faces < 50000, "建筑+道具总面数预算(实际 %d)" % total_faces)

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
