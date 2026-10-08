extends SceneTree

## 结构自检脚本 (headless) — 验证街景 + 咖啡馆 + NPC 与布局一致
## 用法: godot --headless --path godot-project -s res://scripts/debug/street_check.gd
## P2-A: 断言按子系统分组 — 每子系统"产物存在 + 面数 + 位置不越界" + basis 分级
##        + 街区清单三方核对 (manifest == 磁盘 == 运行时重算)。
## P2-B 候选目录版: LV_LAYOUT_CANDIDATE=<布局JSON绝对路径> 切换 —
##        结构核验 + 裸装配器试装配 (五子系统复用性实证), 不加载 main.tscn。

const Planting := preload("res://scripts/world/street/planting.gd")
const BuildingSigns := preload("res://scripts/world/street/building_signs.gd")

var failures: int = 0

func _init():
	_run()

func _run():
	var cand := OS.get_environment("LV_LAYOUT_CANDIDATE")
	if cand != "":
		await _run_candidate(cand)
		return
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
	var n_natural := 0
	var naturals: Array = []
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
			elif nm.begins_with("NaturalEnd_"):
				n_natural += 1
				naturals.append(child)
			# 装饰层抽样: 任取一个装饰道具(树/灯/椅)须在 layer 3(值 4)
			if not decor_layer_ok and child is StaticBody3D \
					and (child as StaticBody3D).collision_layer == 4:
				decor_layer_ok = true
	_check(n_trees >= 6, "行道树 ≥ 6 (实际 %d)" % n_trees)
	_check(n_lamps >= 6, "路灯 ≥ 6 (实际 %d)" % n_lamps)
	_check(n_benches >= 2, "长椅 ≥ 2 (实际 %d)" % n_benches)
	# 端头语义 (决策 11/30): street.ends → open 无封 / natural 花坛护柱 / construction 施工围栏
	var st_ends: Array = layout.get("street", {}).get("ends", ["construction", "construction"])
	var want_bar := 0
	var want_nat := 0
	for k in st_ends:
		match String(k):
			"natural":
				want_nat += 1
			"construction":
				want_bar += 1
	_check(n_barriers == want_bar,
		"施工围栏 Barrier_* == ends 中 construction 端 (期望 %d, 实际 %d)" % [want_bar, n_barriers])
	_check(n_natural == want_nat,
		"自然端 NaturalEnd_* == ends 中 natural 端 (期望 %d, 实际 %d)" % [want_nat, n_natural])

	# 围栏/自然端须在世界层(1)且带碰撞体; 自然端不带文字 (非文字构件)
	var barrier_ok := n_barriers == want_bar
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
	var nat_struct_ok := n_natural == want_nat
	var nat_label_free := true
	for nk in naturals:
		var natb := nk as StaticBody3D
		if natb == null or natb.collision_layer != 1:
			nat_struct_ok = false
			continue
		var nat_shape := false
		for c in natb.get_children():
			if c is CollisionShape3D:
				nat_shape = true
		if not nat_shape:
			nat_struct_ok = false
		if _collect_labels(nk as Node).size() != 0:
			nat_label_free = false
	_check(nat_struct_ok, "自然端 collision_layer==1 且有碰撞体")
	_check(nat_label_free, "自然端无 Label3D (决策11 非文字构件)")

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

	# ── P2-A (预拆分): 路面/人行道 产物 + 位置边界 ──
	var sw := float(layout.get("street", {}).get("width", 9.0))
	var bo := float(layout.get("street", {}).get("backoff", 6.0))
	var road_node: Node = gen.get_node_or_null("Road")
	_check(road_node != null, "路面 Road 节点存在")
	if road_node is StaticBody3D:
		var rb := road_node as StaticBody3D
		_check(rb.collision_layer == 1, "Road collision_layer == 1")
		var r_col := false
		var r_mesh_w := -1.0
		for c in rb.get_children():
			if c is CollisionShape3D:
				r_col = true
			elif c is MeshInstance3D and (c as MeshInstance3D).mesh is BoxMesh:
				r_mesh_w = ((c as MeshInstance3D).mesh as BoxMesh).size.x
		_check(r_col, "Road 有碰撞体")
		_check(absf(r_mesh_w - sw) < 0.01, "路面宽度 == layout.street.width (%.1f, 实际 %.2f)" % [sw, r_mesh_w])
	else:
		_check(false, "Road 类型为 StaticBody3D")
		_check(false, "Road 有碰撞体")
		_check(false, "路面宽度 == layout.street.width")
	var sw_nodes: Array = []
	for nm in ["Sidewalk", "SidewalkM"]:
		var n: Node = gen.get_node_or_null(nm)
		_check(n != null, "人行道 %s 存在" % nm)
		if n:
			sw_nodes.append(n)
	var sw_bounds_ok := sw_nodes.size() == 2
	for n in sw_nodes:
		for c in (n as Node3D).get_children():
			if c is MeshInstance3D and (c as MeshInstance3D).mesh is BoxMesh:
				var bsz: Vector3 = ((c as MeshInstance3D).mesh as BoxMesh).size
				var cx: float = (c as MeshInstance3D).position.x
				if absf(cx) - bsz.x / 2.0 < sw / 2.0 - 0.01 or absf(cx) + bsz.x / 2.0 > bo + 0.01:
					sw_bounds_ok = false
	_check(sw_bounds_ok, "人行道 x ∈ [路宽/2, backoff] 不越界")

	# ── P2-A (预拆分): 道具位置边界 (算术见 street_generator 头注释) ──
	var tree_x_ok := true
	var lamp_x_ok := true
	var bench_ok := true
	var decor_on_road := 0
	var n_trees_exact := 0
	var n_lamps_exact := 0
	if props:
		for child in props.get_children():
			var nm := String(child.name)
			var px: float = 1e9
			if child is Node3D:
				px = (child as Node3D).position.x
			if nm.begins_with("Tree_"):
				n_trees_exact += 1
				if absf(absf(px) - 4.78) > 0.01:
					tree_x_ok = false
			elif nm.begins_with("Lamp_"):
				n_lamps_exact += 1
				if absf(absf(px) - 4.78) > 0.01:
					lamp_x_ok = false
			elif nm.begins_with("Bench_"):
				if absf(px) > bo + 0.01:
					bench_ok = false
			if child is StaticBody3D and (child as StaticBody3D).collision_layer == 4 \
					and absf(px) < sw / 2.0 + 0.05:
				decor_on_road += 1
	_check(n_trees_exact == 11, "行道树精确 11 (12 槽 − 门口缓冲 1, 实际 %d)" % n_trees_exact)
	_check(tree_x_ok, "所有行道树 |x| == 4.78 (路面/巡游带边界)")
	_check(n_lamps_exact == 10, "路灯精确 10 (无避让触发, 实际 %d)" % n_lamps_exact)
	_check(lamp_x_ok, "所有路灯 |x| == 4.78 (路面/巡游带边界)")
	_check(bench_ok, "长椅 |x| ≤ backoff 不越界")
	_check(decor_on_road == 0, "路面区 (|x| < 4.55) 无装饰道具 (实际 %d)" % decor_on_road)

	# 端头构件位置: 布局端点 s0-1 / s1+1 (与生成端同式, 防硬编码漂移);
	# open 端无构件, natural/construction 端各恰 1 个 (决策 11/30)
	var s0_min := 1e9
	var s1_max := -1e9
	for b in layout_buildings:
		s0_min = min(s0_min, float(b["s0"]))
		s1_max = max(s1_max, float(b["s1"]))
	var cap_s0 := 0
	var cap_s1 := 0
	var caps_z_ok := true
	for caps_src in [barriers, naturals]:
		for ck in caps_src:
			if not (ck is Node3D):
				caps_z_ok = false
				continue
			var zv := (ck as Node3D).position.z
			if absf(zv - (s0_min - 1.0)) < 0.01:
				cap_s0 += 1
			elif absf(zv - (s1_max + 1.0)) < 0.01:
				cap_s1 += 1
			else:
				caps_z_ok = false
	var want_cap_s0 := 0 if String(st_ends[0]) == "open" else 1
	var want_cap_s1 := 0 if String(st_ends[1]) == "open" else 1
	_check(caps_z_ok and cap_s0 == want_cap_s0 and cap_s1 == want_cap_s1,
		"端头构件 z 对位且 open 端无封 (s0端 %d/%d, s1端 %d/%d, 期望 s0−1=%.1f / s1+1=%.1f)"
			% [cap_s0, want_cap_s0, cap_s1, want_cap_s1, s0_min - 1.0, s1_max + 1.0])

	# ── P2-A: 子系统模块文件 (所有权契约: scripts/world/street/ 五模块各一写入者) ──
	for fpath in [
		"res://scripts/world/street/road_surface.gd",
		"res://scripts/world/street/planting.gd",
		"res://scripts/world/street/street_furniture.gd",
		"res://scripts/world/street/building_signs.gd",
		"res://scripts/world/street/road_names.gd",
	]:
		_check(FileAccess.file_exists(fpath), "子系统文件存在: %s" % String(fpath).get_file())

	# ── P2-A: planting 预算制计划 (纯函数: 槽位守恒/原因闭集/可覆盖参数) ──
	var plan: Dictionary = Planting.new().plan()
	var planted := int(plan["planted"])
	var rejected: Array = plan["rejected"]
	_check(planted + rejected.size() == 12,
		"planting 槽位守恒 planted+rejected==12 (实际 %d+%d)" % [planted, rejected.size()])
	_check(planted == 11, "planting 默认计划 11 (12 槽 − 门口缓冲 1, 实际 %d)" % planted)
	var reasons_ok := rejected.size() > 0
	var door_hit := false
	for rj in rejected:
		var rsn := String((rj as Dictionary)["reason"])
		if not Planting.REASONS.has(rsn):
			reasons_ok = false
		if rsn == "cafe_door_buffer" and float((rj as Dictionary)["side"]) > 0.0:
			door_hit = true
	_check(reasons_ok, "拒绝原因全部 ∈ REASONS 闭集")
	_check(door_hit, "门口缓冲拒绝存在 (side=+1)")
	var low: Dictionary = Planting.plan_with(Planting.PARAMS, {"budget_total": 3})
	var exhausted := false
	for rj in low["rejected"]:
		if String((rj as Dictionary)["reason"]) == "budget_exhausted":
			exhausted = true
	_check(int(low["planted"]) == 3 and exhausted,
		"覆盖预算 budget=3 → planted==3 且出现 budget_exhausted (实际 %d)" % int(low["planted"]))
	var door_sync := absf(float(Planting.PARAMS["cafe_door_z"])
		- float(layout.get("cafe_anchor", {}).get("s", -999.0))) < 0.001
	_check(door_sync, "planting.cafe_door_z == layout.cafe_anchor.s (双源同步)")

	# ── P2-A: building_signs 铭牌 (产物/内容/basis/位置) ──
	var signs_root: Node = null
	if bld_root:
		signs_root = bld_root.get_node_or_null("BuildingSigns")
	_check(signs_root != null, "BuildingSigns 容器存在")
	var sign_nodes: Array = []
	if signs_root:
		for c in signs_root.get_children():
			sign_nodes.append(c)
	_check(sign_nodes.size() == 1,
		"铭牌数 == OSM 相邻同名合并段 (实际 %d, 期望 1)" % sign_nodes.size())
	var layout_names: Dictionary = {}
	var nmin := 1e9
	var nmax := -1e9
	for b in layout_buildings:
		var bn := String(b.get("name", "")).strip_edges()
		if bn != "":
			layout_names[bn] = true
			nmin = min(nmin, float(b["s0"]))
			nmax = max(nmax, float(b["s1"]))
	var sign_lbl: Label3D = null
	if sign_nodes.size() == 1:
		sign_lbl = _first_label(sign_nodes[0] as Node)
	_check(sign_lbl != null and layout_names.has(sign_lbl.text),
		"铭牌文字 ∈ 布局 OSM 名集合 (实际 %s)" % (sign_lbl.text if sign_lbl else "<无Label>"))
	_check(sign_lbl != null and String(sign_lbl.get_meta("basis", "")) == "reported",
		"铭牌 basis == reported (OSM name)")
	var sign_pos_ok := false
	if sign_nodes.size() == 1 and sign_nodes[0] is Node3D:
		var sn := sign_nodes[0] as Node3D
		sign_pos_ok = absf(absf(sn.position.x) - bo) < 0.5 \
			and absf(sn.position.y - 3.2) < 0.01 \
			and sn.position.z >= nmin - 0.01 and sn.position.z <= nmax + 0.01
	_check(sign_pos_ok, "铭牌贴立面前伸不越界 (|x|<backoff, y=3.2, z∈命名楼段)")

	# ── P2-A: road_names 路名牌 (产物/端点/文字分级/朝向) ──
	var rn_root: Node = null
	if bld_root:
		rn_root = bld_root.get_node_or_null("RoadNames")
	_check(rn_root != null, "RoadNames 容器存在")
	var plates: Array = []
	if rn_root:
		for c in rn_root.get_children():
			plates.append(c)
	_check(plates.size() == 2, "路名牌 2 块 (南/北端, 实际 %d)" % plates.size())
	if plates.size() == 2:
		plates.sort_custom(func(a, b): return (a as Node3D).position.z < (b as Node3D).position.z)
		var ps := plates[0] as Node3D
		var pn := plates[1] as Node3D
		_check(absf(ps.position.z - (s0_min - 1.0 + 2.0)) < 0.01 \
			and absf(pn.position.z - (s1_max + 1.0 - 2.0)) < 0.01,
			"路名牌 z == 布局端点内缩 2m (南 %.2f, 北 %.2f)" % [ps.position.z, pn.position.z])
		_check(absf(absf(ps.position.x) - 4.9) < 0.01 and absf(absf(pn.position.x) - 4.9) < 0.01,
			"路名牌 x == 4.9 (人行道内侧不越界)")
		var street_nm := String(layout.get("street", {}).get("name", ""))
		var name_ok := true
		var dir_ok := true
		var orient_ok := true
		for plate_info in [[ps, 0.0], [pn, 180.0]]:
			var pl := (plate_info[0] as Node3D).get_node_or_null("StreetName") as Label3D
			var dl := (plate_info[0] as Node3D).get_node_or_null("DirHint") as Label3D
			if pl == null or pl.text != street_nm or String(pl.get_meta("basis", "")) != "reported":
				name_ok = false
			if dl == null or String(dl.get_meta("basis", "")) != "ai-drafted" \
					or not ["vers le Nord", "vers le Sud"].has(dl.text):
				dir_ok = false
			if pl == null or absf(pl.rotation_degrees.y - float(plate_info[1])) > 0.01:
				orient_ok = false
		_check(name_ok, "路名主行 == 布局街名且 basis == reported (\"%s\")" % street_nm)
		_check(dir_ok, "方位词 basis == ai-drafted 且 ∈ {Nord, Sud}")
		_check(orient_ok, "路名行朝向街内 (南 0° / 北 180°)")

	# ── P2-A: 文字 basis 分级 (围栏施工文案 / 咖啡馆店名) ──
	# 围栏存在时必带文案且全部 ai-drafted (rosiers ends=open,natural → 0 围栏, 空真)
	var bar_basis := true
	for bk in barriers:
		var blabs: Array = _collect_labels(bk as Node)
		if blabs.is_empty():
			bar_basis = false  # 施工围栏必带标牌文案
		for lab in blabs:
			if String((lab as Label3D).get_meta("basis", "")) != "ai-drafted":
				bar_basis = false
	_check(bar_basis, "围栏施工文案 basis == ai-drafted (围栏 %d 道)" % n_barriers)
	_check(cafe_site != null and String(cafe_site.get_meta("basis", "")) == "reported",
		"咖啡馆店名 basis == reported (OSM name)")

	# ── P2-A: 街区清单三方核对 (manifest == 磁盘 == 运行时重算) ──
	var block: Dictionary = {}
	var mf := FileAccess.open("res://data/assets_manifest.json", FileAccess.READ)
	if mf:
		var mjson = JSON.parse_string(mf.get_as_text())
		if typeof(mjson) == TYPE_DICTIONARY:
			block = ((mjson as Dictionary).get("blocks", {}) as Dictionary).get("rosiers", {})
	_check(not block.is_empty(), "assets_manifest.blocks.rosiers 街区 entry 存在")
	var runtime: Dictionary = gen.get_block_manifest()
	if OS.get_environment("LV_DUMP_BLOCK_MANIFEST") != "":
		print("BLOCK_MANIFEST_JSON: ", JSON.stringify(runtime))
	if not block.is_empty():
		var rlayout: Dictionary = runtime["layout"]
		var mlayout: Dictionary = block.get("layout", {})
		_check(String(mlayout.get("sha256", "")) == String(rlayout["sha256"]) \
			and int(mlayout.get("bytes", -1)) == int(rlayout["bytes"]),
			"layout sha256/bytes 三方一致 (清单==磁盘)")
		var msub: Dictionary = block.get("subsystems", {})
		var rsub: Dictionary = runtime["subsystems"]
		var drift := ""
		for k in rsub:
			if String(msub.get(k, "")) != String(rsub[k]):
				drift += String(k) + " "
		if msub.size() != rsub.size():
			drift += "(数量 %d≠%d)" % [msub.size(), rsub.size()]
		_check(drift == "", "5 子系统 param_hash 与运行时一致 (漂移: %s)" % (drift if drift != "" else "无"))
	else:
		_check(false, "layout sha256/bytes 三方一致 (清单==磁盘)")
		_check(false, "5 子系统 param_hash 与运行时一致")

	# ── P3 批次1: blocks.vosges 三方核对 (清单==磁盘==运行时子系统) ──
	var vblock: Dictionary = {}
	if mf:
		var mjson2 = JSON.parse_string(mf.get_as_text())
		if typeof(mjson2) == TYPE_DICTIONARY:
			vblock = ((mjson2 as Dictionary).get("blocks", {}) as Dictionary).get("vosges", {})
	_check(not vblock.is_empty(), "assets_manifest.blocks.vosges 街区 entry 存在")
	if not vblock.is_empty():
		var vl: Dictionary = vblock.get("layout", {})
		var vpath := String(vl.get("path", "")).replace("godot-project/", "res://")
		var vf := FileAccess.open(vpath, FileAccess.READ)
		_check(vf != null, "vosges 布局磁盘可读 (%s)" % vpath)
		if vf:
			var vraw := vf.get_buffer(vf.get_length())
			var vsha := _sha256_hex(vraw)
			_check(String(vl.get("sha256", "")) == vsha and int(vl.get("bytes", -1)) == vraw.size(),
				"vosges layout 清单==磁盘 (sha %s…, %d B)" % [vsha.substr(0, 12), vraw.size()])
			var vjson = JSON.parse_string(vraw.get_string_from_utf8())
			var vok := typeof(vjson) == TYPE_DICTIONARY
			if vok:
				var vst: Dictionary = (vjson as Dictionary).get("street", {})
				var vb = (vjson as Dictionary).get("buildings", [])
				vok = vst.get("placement", "") == "by_v" \
					and vst.get("slots") is Dictionary \
					and vb is Array and (vb as Array).size() >= 50
			_check(vok, "vosges 结构: placement=by_v + slots + ≥50 栋")
		var vsub: Dictionary = vblock.get("subsystems", {})
		var rsub2: Dictionary = runtime["subsystems"]
		var vdrift := ""
		for k in rsub2:
			if String(vsub.get(k, "")) != String(rsub2[k]):
				vdrift += String(k) + " "
		if vsub.size() != rsub2.size():
			vdrift += "(数量 %d≠%d)" % [vsub.size(), rsub2.size()]
		_check(vdrift == "", "vosges 5 子系统 param_hash 与运行时一致 (漂移: %s)" % (vdrift if vdrift != "无" and vdrift != "" else "无"))
	else:
		_check(false, "assets_manifest.blocks.vosges 街区 entry 存在")
		_check(false, "vosges 结构: placement=by_v + slots + ≥50 栋")
		_check(false, "vosges 5 子系统 param_hash 与运行时一致")

	# ═══════ P3 批次2: 两街同场景 + 接缝 (决策 30 方案A — 接缝在游戏空间直链) ═══════
	var gens: Array = get_nodes_in_group("street_generator")
	_check(gens.size() == 3, "3 个 StreetGenerator 同场景 (rosiers/vosges/corridor, 实际 %d)" % gens.size())
	var vgen: Node = main.get_node_or_null("StreetGeneratorVosges")
	var cgen: Node = main.get_node_or_null("StreetGeneratorCorridor")
	_check(vgen != null, "StreetGeneratorVosges 存在")
	_check(cgen != null, "StreetGeneratorCorridor 存在")

	# ── blocks.corridor 三方核对 (清单==磁盘==运行时子系统) ──
	var cblock: Dictionary = {}
	if mf:
		var mjson3 = JSON.parse_string(mf.get_as_text())
		if typeof(mjson3) == TYPE_DICTIONARY:
			cblock = ((mjson3 as Dictionary).get("blocks", {}) as Dictionary).get("corridor", {})
	_check(not cblock.is_empty(), "assets_manifest.blocks.corridor 街区 entry 存在")
	if not cblock.is_empty():
		var cl: Dictionary = cblock.get("layout", {})
		var cpath := String(cl.get("path", "")).replace("godot-project/", "res://")
		var cf := FileAccess.open(cpath, FileAccess.READ)
		_check(cf != null, "corridor 布局磁盘可读 (%s)" % cpath)
		if cf:
			var craw := cf.get_buffer(cf.get_length())
			var csha := _sha256_hex(craw)
			_check(String(cl.get("sha256", "")) == csha and int(cl.get("bytes", -1)) == craw.size(),
				"corridor layout 清单==磁盘 (sha %s…, %d B)" % [csha.substr(0, 12), craw.size()])
		if cgen != null:
			var cruntime: Dictionary = (cgen as Node).call("get_block_manifest")
			var csub: Dictionary = cblock.get("subsystems", {})
			var crr: Dictionary = cruntime.get("subsystems", {})
			var cdrift := ""
			for k in crr:
				if String(csub.get(k, "")) != String(crr[k]):
					cdrift += String(k) + " "
			if csub.size() != crr.size():
				cdrift += "(数量 %d≠%d)" % [csub.size(), crr.size()]
			_check(cdrift == "", "corridor 5 子系统 param_hash 与运行时一致 (漂移: %s)" % (cdrift if cdrift != "" else "无"))
	else:
		_check(false, "corridor layout 清单==磁盘")

	# ── 每街结构核验 (决策 29 单街 ≤25k + ends 语义 + road_limits 运行时口径) ──
	_check_street(vgen, "vosges")
	_check_street(cgen, "corridor")

	# ── 接缝闭环: meta.placement ↔ 节点变换 ↔ 路面端世界几何 (Δ<0.5m) ──
	var ident_ok := (gen as Node3D).position == Vector3.ZERO \
		and absf((gen as Node3D).rotation.y) < 1e-6
	_check(ident_ok, "接缝0 rosiers 恒等变换 (ref 街, pos=%s rot=%.4f°)"
		% [(gen as Node3D).position, rad_to_deg((gen as Node3D).rotation.y)])
	for gpair in [["corridor", cgen], ["vosges", vgen]]:
		var g2: Node = gpair[1]
		if g2 == null:
			_check(false, "接缝(%s): 生成器缺失" % gpair[0])
			continue
		var m2: Dictionary = (g2.layout as Dictionary).get("meta", {})
		var p2: Dictionary = m2.get("placement", {})
		var pos_want := Vector3(float(p2.get("x", 0.0)), 0.0, float(p2.get("z", 0.0)))
		var rot_want := deg_to_rad(
			float(m2.get("street_axis_deg", 0.0)) - float(p2.get("ref_axis", 0.0)))
		var pgot := (g2 as Node3D).position
		var rgot := (g2 as Node3D).rotation.y
		_check(String(p2.get("ref", "")) == "rosiers" \
			and absf(pgot.x - pos_want.x) < 0.02 and absf(pgot.z - pos_want.z) < 0.02,
			"接缝(%s): position == meta.placement (%.2f, %.2f)" % [gpair[0], pgot.x, pgot.z])
		_check(_ang_diff(rgot, rot_want) < deg_to_rad(0.15),
			"接缝(%s): rotation.y == my_axis − ref_axis (%.3f°)"
				% [gpair[0], rad_to_deg(rgot)])
	# 接缝1: 罗斯路面 min 端世界 == 走廊路面 min 端世界 (joint, 方案A 构造性)
	var seam1 := 1e9
	if cgen != null:
		seam1 = _road_end_world(gen, false).distance_to(_road_end_world(cgen, false))
	_check(seam1 < 0.5, "接缝1 罗斯→走廊 路面端世界 Δ = %.3fm (<0.5)" % seam1)
	# 接缝2: 走廊路面 max 端世界 == Vosges 锚 (local (0,0,anchor_s)) 世界
	var seam2 := 1e9
	if cgen != null and vgen != null:
		var vpl: Dictionary = ((vgen.layout as Dictionary).get("meta", {}) as Dictionary) \
			.get("placement", {})
		var anch: Array = vpl.get("anchor", [0.0, 0.0])
		var anchor_world := (vgen as Node3D).global_transform * Vector3(0.0, 0.0, float(anch[1]))
		seam2 = _road_end_world(cgen, true).distance_to(anchor_world)
	_check(seam2 < 0.5, "接缝2 走廊→Vosges 锚世界 Δ = %.3fm (<0.5)" % seam2)
	# 接缝数据链: 走廊链终点 == FB×环触点 → total_len == z_fb (离线断言的运行时回读)
	if cgen != null:
		var cst: Dictionary = (cgen.layout as Dictionary).get("street", {})
		_check(float(cst.get("total_len", 0.0)) > 300.0 \
			and cst.get("ends", []) is Array and (cst.get("ends", []) as Array) == ["open", "open"],
			"接缝数据: corridor total_len=%.0f 且 ends==[open,open]" % float(cst.get("total_len", 0.0)))

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

	# 面数估算 (决策 29): 单街 ≤25,000 + 三街总门禁 —
	# 遍历全部 generator 的 buildings_root (含 StreetProps 道具)
	var total_faces := 0
	var per_gen_faces: Dictionary = {}
	var under_single := true
	for g3 in gens:
		var gf := 0
		var gbr: Node = (g3 as Node).get("buildings_root")
		if gbr:
			for child in gbr.get_children():
				for mesh_node in _collect_mesh(child):
					gf += _mesh_faces(mesh_node)
		per_gen_faces[String((g3 as Node).name)] = gf
		total_faces += gf
		if gf > 25000:
			under_single = false
	_check(under_single, "单街面数 ≤25000 (%s)" % JSON.stringify(per_gen_faces))
	var prop_faces := 0
	if props:
		for child in props.get_children():
			for mesh_node in _collect_mesh(child):
				prop_faces += _mesh_faces(mesh_node)
	print("[StreetCheck] 各生成器面数: ", JSON.stringify(per_gen_faces))
	print("[StreetCheck] 建筑估算面数(rosiers): ", total_faces - prop_faces)
	print("[StreetCheck] 道具估算面数(rosiers): ", prop_faces)
	_check(total_faces < 50000, "三街建筑+道具总面数预算(实际 %d < 50000)" % total_faces)

	main.queue_free()
	_quit()

func _collect_mesh(node: Node, acc: Array = []) -> Array:
	if node is MeshInstance3D:
		acc.append(node)
	for c in node.get_children():
		_collect_mesh(c, acc)
	return acc

## 收集 Label3D (basis 分级断言用)
func _sha256_hex(data: PackedByteArray) -> String:
	var hc := HashingContext.new()
	if hc.start(HashingContext.HASH_SHA256) != OK:
		return ""
	var digest := hc.update(data)
	if digest != OK:
		return ""
	var out := hc.finish()
	var hex := ""
	for b in out:
		hex += "%02x" % b
	return hex

func _collect_labels(node: Node, acc: Array = []) -> Array:
	if node is Label3D:
		acc.append(node)
	for c in node.get_children():
		_collect_labels(c, acc)
	return acc

## 取第一个 Label3D (铭牌文字断言用)
func _first_label(node: Node) -> Label3D:
	var found := _collect_labels(node)
	if found.size() == 0:
		return null
	return found[0] as Label3D

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

## ---------- P2-B 候选目录版 ----------
## LV_LAYOUT_CANDIDATE=<绝对路径> 时执行: 布局结构核验 + 裸装配器试装配。
## 不加载 main.tscn (无 NPC/玩家), Rosiers 专属断言不适用; 通过 ≠ 视觉验收。
func _run_candidate(path: String):
	print("[StreetCheck] 模式: 候选目录版 — ", path)
	var fa := FileAccess.open(path, FileAccess.READ)
	_check(fa != null, "候选文件可读 (绝对路径)")
	if fa == null:
		_quit()
		return
	var parsed = JSON.parse_string(fa.get_as_text())
	_check(parsed is Dictionary, "JSON 解析为对象")
	if not (parsed is Dictionary):
		_quit()
		return
	var layout: Dictionary = parsed
	var meta: Dictionary = layout.get("meta", {})
	var st: Dictionary = layout.get("street", {})
	_check(String(meta.get("source", "")).find("OpenStreetMap") >= 0,
		"meta.source 标注 OpenStreetMap (ODbL)")
	_check(String(st.get("name", "")).strip_edges() != "", "street.name 非空")
	var total_len := float(st.get("total_len", 0.0))
	_check(total_len >= 100.0, "中线总长 ≥100m (实际 %.0fm)" % total_len)
	_check(String(st.get("placement", "")) == "by_v",
		"placement == by_v (OSM 真实投影摆楼)")
	var width := float(st.get("width", 0.0))
	var backoff := float(st.get("backoff", 0.0))
	_check(width > 0.0 and backoff > width / 2.0,
		"width>0 且 backoff > 半路宽 (实际 %.1f/%.1f)" % [width, backoff])

	var bs: Array = layout.get("buildings", [])
	_check(bs.size() >= 20, "候选建筑 ≥20 栋 (实际 %d)" % bs.size())
	var finite_ok := true
	var span_ok := true
	var face_ok := true
	var lv_ok := true
	var side_n := {1: 0, -1: 0}
	var side_span := {1: 0.0, -1: 0.0}
	var side_min := {1: 1e9, -1: 1e9}
	var side_max := {1: -1e9, -1: -1e9}
	for b in bs:
		var side := 1.0 if float(b["side"]) >= 0.0 else -1.0
		var s0 := float(b["s0"])
		var s1 := float(b["s1"])
		var v := float(b.get("v", 0.0))
		var d := float(b.get("depth", 0.0))
		var lv := int(b.get("levels", 0))
		var h := float(b.get("height", 0.0))
		if not (is_finite(s0) and is_finite(s1) and is_finite(v) and is_finite(d)):
			finite_ok = false
		if s0 >= s1 or s1 - s0 > 60.0:
			span_ok = false
		# by_v 立面 (与装配器 get_facade_face 同式): 不穿进路面
		var face: float = maxf(backoff, absf(v) - d / 2.0)
		if face < width / 2.0 + 0.5:
			face_ok = false
		if lv < 2 or lv > 12 or absf(h - float(lv) * 3.2) > 0.11:
			lv_ok = false
		var k := int(side)
		side_n[k] = side_n[k] + 1
		side_min[k] = minf(side_min[k], s0)
		side_max[k] = maxf(side_max[k], s1)
	for k in side_span:
		side_span[k] = side_max[k] - side_min[k]
	_check(finite_ok, "全部字段有限 (无 NaN/Inf)")
	_check(span_ok, "跨度合法 (s0<s1 且单栋 ≤60m, 防投影翻车)")
	_check(face_ok, "by_v 立面全不穿路面 (face ≥ 半路宽+0.5)")
	_check(lv_ok, "层数 2-12 且 height==levels*3.2")
	var main_side := 1 if side_n[1] >= side_n[-1] else -1
	_check(side_span[main_side] >= total_len * 0.5,
		"主侧覆盖 ≥50%% 中线 (%d 侧覆盖 %.0f/%.0fm)"
			% [main_side, side_span[main_side], total_len])
	var runs: Array = BuildingSigns.name_runs(layout, BuildingSigns.PARAMS)
	_check(runs.size() >= 1, "命名楼段可合并为铭牌 run (实际 %d)" % runs.size())

	# ── P3 批次1: 槽位参数化 (street.slots 覆盖灯具/长椅/种植) ──
	var slots_v = st.get("slots", {})
	var slots: Dictionary = slots_v if slots_v is Dictionary else {}
	_check(slots.size() >= 3, "street.slots 槽位存在 (lamp/bench/planting, 实际 %d 键)" % slots.size())
	var gs_min := 1e9
	var gs_max := -1e9
	for b in bs:
		gs_min = minf(gs_min, float(b["s0"]))
		gs_max = maxf(gs_max, float(b["s1"]))
	if slots.size() >= 3:
		var lampz: Array = slots.get("lamp_z", [])
		var lamp_ok := lampz.size() >= 5 \
			and float(lampz[0]) >= gs_min and float(lampz[lampz.size() - 1]) <= gs_max
		_check(lamp_ok, "灯具槽位 ≥5 点且落在建筑跨度内 (%d 点, %.0f..%.0f)"
			% [lampz.size(), float(lampz[0]) if lampz.size() > 0 else -1.0,
				float(lampz[lampz.size() - 1]) if lampz.size() > 0 else -1.0])
		var pinfo: Dictionary = slots.get("planting", {})
		var tree_last := float(pinfo.get("z_from", -1e9)) \
			+ (float(pinfo.get("z_count", 0)) - 1.0) * float(pinfo.get("z_step", 1.0))
		var cover_ok := float(pinfo.get("z_from", 1e9)) >= gs_min \
			and tree_last <= gs_max \
			and float(pinfo.get("budget_total", 0)) >= 2.0 * float(pinfo.get("z_count", 0)) \
			and float(pinfo.get("cafe_door_z", 0.0)) < -9000.0  # 无咖啡馆: 幻影缓冲须关闭
		_check(cover_ok, "种植网格覆盖全段 (14..%.0f / 预算 %d) 且幻影缓冲关闭"
			% [tree_last, int(pinfo.get("budget_total", 0))])

	# ---- 试装配: 裸 StreetGenerator 消费该布局 (五子系统复用性实证) ----
	var gen: Node = (load("res://scripts/world/street_generator.gd") as GDScript).new()
	gen.layout_path = path
	root.add_child(gen)
	await process_frame
	await process_frame
	_check(gen.layout.size() > 0, "装配器读入候选布局")
	var bld_root: Node = gen.buildings_root
	_check(bld_root != null, "Buildings 根存在")
	var n_gen := 0
	if bld_root:
		for c in bld_root.get_children():
			if String(c.name).begins_with("Building_"):
				n_gen += 1
	_check(n_gen > 0 and n_gen <= bs.size(),
		"生成建筑 %d 栋 (0<n≤候选 %d)" % [n_gen, bs.size()])
	var containers := ["Road", "Sidewalk", "StreetProps", "BuildingSigns", "RoadNames"]
	var all_c := true
	var missing := ""
	for cname in containers:
		var n: Node = null
		if cname == "Road" or cname == "Sidewalk":
			n = gen.get_node_or_null(cname)
		elif cname == "StreetProps":
			n = bld_root.get_node_or_null(cname) if bld_root else null
		else:
			n = bld_root.get_node_or_null(cname) if bld_root else null
		if n == null:
			all_c = false
			missing += cname + " "
	_check(all_c, "五子系统容器齐 (缺: %s)" % ("无" if all_c else missing))
	# 摆楼实证: 节点 x == side * get_facade_face(b) (by_v)
	var place_ok := true
	for b in bs:
		var idn := int(b["id"])
		var nd: Node = bld_root.get_node_or_null("Building_%d" % idn) if bld_root else null
		if nd == null:
			continue  # cafe 清除区跳过的不在此断言
		var side := 1.0 if float(b["side"]) >= 0.0 else -1.0
		var face: float = gen.get_facade_face(b)
		var want: float = side * face
		if absf((nd as Node3D).position.x - want) > 0.01:
			place_ok = false
	_check(place_ok, "摆楼 x == side*get_facade_face (by_v 逐栘认证)")
	# 面数预算: 单街区 ≤25,000 (P2-B 原 20k; 决策 29 修订 2026-10-08 —
	# Vosges 495m 环实测 20316 撞线, 道具占 88%, 批次5 GLB 替换后复核定值)
	var faces := 0
	for m in _collect_mesh(gen):
		faces += _mesh_faces(m)
	_check(faces <= 25000, "候选单街区面数 ≤25000 (实际 %d)" % faces)
	# 铭牌 basis 分级 + 贴立面
	var signs: Node = bld_root.get_node_or_null("BuildingSigns") if bld_root else null
	if signs:
		var sign_ok := true
		var attach_ok := true
		var labels_ok := true
		var idx := 0
		for c in signs.get_children():
			if not String(c.name).begins_with("Sign_"):
				continue
			var r: Dictionary = runs[idx] if idx < runs.size() else {}
			idx += 1
			var lb := _first_label(c)
			if lb == null or String(lb.get_meta("basis", "")) != "reported":
				labels_ok = false
			if r.is_empty():
				continue
			var side := float(r["side"])
			var rface: float = gen.get_facade_face(r)
			var want_x: float = side * (rface - float(BuildingSigns.PARAMS["face_offset"]))
			if absf((c as Node3D).position.x - want_x) > 0.01:
				attach_ok = false
		_check(sign_ok and labels_ok, "铭牌 Label3D basis==reported (run 数 %d)" % idx)
		_check(attach_ok, "铭牌贴 by_v 立面 (x==side*(face-face_offset))")
	else:
		_check(false, "BuildingSigns 容器存在")
	# 路名牌: 名称与主街一致 + 方位词 ai-drafted
	var rn: Node = bld_root.get_node_or_null("RoadNames") if bld_root else null
	if rn:
		var name_ok := true
		var dir_ok := true
		for plate in rn.get_children():
			var nm := _first_label(plate)
			if nm == null or String(nm.text) != String(st.get("name", "")) \
					or String(nm.get_meta("basis", "")) != "reported":
				name_ok = false
		_check(name_ok, "路名牌主行 == street.name 且 basis reported")
		for plate in rn.get_children():
			var dl := plate.get_node_or_null("DirHint")
			if dl == null or String((dl as Label3D).get_meta("basis", "")) != "ai-drafted":
				dir_ok = false
		_check(dir_ok, "方位词 basis ai-drafted (游戏世界口径)")
	else:
		_check(false, "RoadNames 容器存在")
	print("[StreetCheck] 候选统计: 建筑 %d / 生成 %d / 面数 %d / 主侧覆盖 %.0fm"
		% [bs.size(), n_gen, faces, side_span[main_side]])
	_quit()


## 角度差 (弧度, 折回 ±π)
func _ang_diff(a: float, b: float) -> float:
	return absf(fmod(a - b + PI, TAU) - PI)

## 路面端世界坐标: at_max=false → z 最小端; true → z 最大端 (mesh 中心 ± 半长)
func _road_end_world(g: Node, at_max: bool) -> Vector3:
	if g == null:
		return Vector3(1e9, 1e9, 1e9)
	var road: Node = g.get_node_or_null("Road")
	if road == null:
		return Vector3(1e9, 1e9, 1e9)
	var zmid := 0.0
	var half := 0.0
	for c in (road as Node3D).get_children():
		if c is MeshInstance3D and (c as MeshInstance3D).mesh is BoxMesh:
			zmid = (c as Node3D).position.z
			half = ((c as MeshInstance3D).mesh as BoxMesh).size.z / 2.0
	var z := (zmid + half) if at_max else (zmid - half)
	return (g as Node3D).global_transform * Vector3(0.0, 0.0, z)

## P3 批次2: 每街结构核验 (≈34 断言/街 — vosges+corridor 共 ~68, P2-B 两街 ≥50 硬验收)
## 覆盖: 布局载入/建筑/碰撞/单街面数/路面(宽+范围公式+drop)/人行道/道具/
##       端头语义(ends)/路名牌(basis)/铭牌容器。
func _check_street(g: Node, label: String) -> void:
	_check(g != null, label + ": 生成器存在")
	if g == null:
		return
	var lay: Dictionary = g.layout
	_check(lay.size() > 0, label + ": 布局已载入")
	if lay.is_empty():
		return
	var st: Dictionary = lay.get("street", {})
	var bs: Array = lay.get("buildings", [])
	_check(bs.size() >= 20, "%s: 布局建筑 ≥20 (实际 %d)" % [label, bs.size()])
	var sw := float(st.get("width", 9.0))
	var bo := float(st.get("backoff", 6.0))
	_check(sw > 0.0 and bo > sw / 2.0, "%s: width>0 且 backoff>半路宽 (%.1f/%.1f)" % [label, sw, bo])

	# 建筑: 生成数 ∈ (0, 布局数] + 全碰撞 + 单街面数 ≤25000 (决策 29)
	var br: Node = g.get("buildings_root")
	_check(br != null, label + ": Buildings 根存在")
	var n_gen := 0
	var no_col := 0
	var faces := 0
	if br:
		for c in br.get_children():
			for mn in _collect_mesh(c):
				faces += _mesh_faces(mn)
			if String(c.name).begins_with("Building_"):
				n_gen += 1
				var has := false
				for cc in c.get_children():
					if cc is CollisionShape3D:
						has = true
				if not has:
					no_col += 1
	_check(n_gen > 0 and n_gen <= bs.size(), "%s: 生成建筑 %d ∈ (0,%d]" % [label, n_gen, bs.size()])
	_check(no_col == 0, "%s: 建筑全有碰撞体 (缺 %d)" % [label, no_col])
	_check(faces <= 25000, "%s: 单街面数 ≤25000 (实际 %d)" % [label, faces])

	# 路面: 存在/layer1/碰撞/宽 + 范围 == ends·road_limits 公式 + surface_drop 生效
	var s0m := 1e9
	var s1m := -1e9
	for b in bs:
		s0m = minf(s0m, float(b["s0"]))
		s1m = maxf(s1m, float(b["s1"]))
	var want_min := s0m - 14.0
	var want_max := s1m + 14.0
	var ek: Array = st.get("ends", [])
	var rl: Array = st.get("road_limits", [])
	if ek.size() >= 2 and rl.size() >= 2:
		if String(ek[0]) == "open":
			want_min = maxf(want_min, float(rl[0]))
		if String(ek[1]) == "open":
			want_max = float(rl[1])
	var road: Node = g.get_node_or_null("Road")
	_check(road is StaticBody3D, label + ": Road 存在且为 StaticBody3D")
	if road is StaticBody3D:
		_check((road as StaticBody3D).collision_layer == 1, label + ": Road collision_layer==1")
		var r_w := -1.0
		var r_zmid := 0.0
		var r_half := 0.0
		var r_y := 0.0
		var r_h := 0.0
		var r_drop_ok := false
		var r_col := false
		for c in (road as Node3D).get_children():
			if c is CollisionShape3D:
				r_col = true
			elif c is MeshInstance3D and (c as MeshInstance3D).mesh is BoxMesh:
				var bsz: Vector3 = ((c as MeshInstance3D).mesh as BoxMesh).size
				r_w = bsz.x
				r_h = bsz.y
				r_half = bsz.z / 2.0
				r_zmid = (c as Node3D).position.z
				r_y = (c as Node3D).position.y
				var drop := float(st.get("surface_drop", 0.0))
				r_drop_ok = absf(r_y - (-bsz.y / 2.0 - drop)) < 0.002
		_check(r_col, label + ": Road 有碰撞体")
		_check(absf(r_w - sw) < 0.01, "%s: 路面宽 %.2f == street.width %.1f" % [label, r_w, sw])
		_check(absf((r_zmid - r_half) - want_min) < 0.02 and absf((r_zmid + r_half) - want_max) < 0.02,
			"%s: 路面范围 == ends/road_limits 公式 [%.1f, %.1f] (实 [%.1f, %.1f])"
				% [label, want_min, want_max, r_zmid - r_half, r_zmid + r_half])
		_check(r_drop_ok, "%s: surface_drop 口径 (y=%.4f, 期望 %.4f)"
			% [label, r_y, -r_h / 2.0 - float(st.get("surface_drop", 0.0))])

	# 人行道: 双侧存在 + x ∈ [半路宽, backoff]
	var sw_nodes: Array = []
	for nm3 in ["Sidewalk", "SidewalkM"]:
		var n3: Node = g.get_node_or_null(nm3)
		if n3 != null:
			sw_nodes.append(n3)
	_check(sw_nodes.size() == 2, label + ": 双侧人行道存在 (%d/2)" % sw_nodes.size())
	var swb_ok := sw_nodes.size() == 2
	for n3 in sw_nodes:
		for c in (n3 as Node3D).get_children():
			if c is MeshInstance3D and (c as MeshInstance3D).mesh is BoxMesh:
				var bsz2: Vector3 = ((c as MeshInstance3D).mesh as BoxMesh).size
				var cx: float = (c as Node3D).position.x
				if absf(cx) - bsz2.x / 2.0 < sw / 2.0 - 0.01 or absf(cx) + bsz2.x / 2.0 > bo + 0.01:
					swb_ok = false
	_check(swb_ok, label + ": 人行道 x ∈ [半路宽, backoff] 不越界")

	# 道具: 容器 + 树/灯/椅 + x 口径 + 路面区无装饰
	var propsn: Node = null
	if br:
		propsn = br.get_node_or_null("StreetProps")
	_check(propsn != null, label + ": StreetProps 存在")
	var n_tr := 0
	var n_lp := 0
	var n_bn := 0
	var x_ok := true
	var decor_road := 0
	if propsn:
		for c in propsn.get_children():
			var nm4 := String(c.name)
			var px := 1e9
			if c is Node3D:
				px = (c as Node3D).position.x
			if nm4.begins_with("Tree_"):
				n_tr += 1
				if absf(absf(px) - 4.78) > 0.01:
					x_ok = false
			elif nm4.begins_with("Lamp_"):
				n_lp += 1
				if absf(absf(px) - 4.78) > 0.01:
					x_ok = false
			elif nm4.begins_with("Bench_"):
				n_bn += 1
				if absf(px) > bo + 0.01:
					x_ok = false
			if c is StaticBody3D and (c as StaticBody3D).collision_layer == 4 \
					and absf(px) < sw / 2.0 + 0.05:
				decor_road += 1
	_check(n_tr >= 4, "%s: 行道树 ≥4 (实际 %d)" % [label, n_tr])
	_check(n_lp >= 6, "%s: 路灯 ≥6 (实际 %d)" % [label, n_lp])
	_check(n_bn >= 2, "%s: 长椅 ≥2 (实际 %d)" % [label, n_bn])
	_check(x_ok, "%s: 树/灯 |x|==4.78, 椅 ≤backoff" % label)
	_check(decor_road == 0, "%s: 路面区无装饰道具 (实际 %d)" % [label, decor_road])

	# 端头语义: 构件计数/结构/文字缺席/z 对位 (决策 11/30)
	var expect: Array = ek if ek.size() >= 2 else ["construction", "construction"]
	var n_nat := 0
	var n_bar := 0
	var nat_label_free := true
	var nat_col_ok := true
	var caps_z_ok := true
	var cap_s0 := 0
	var cap_s1 := 0
	if propsn:
		for c in propsn.get_children():
			var nm5 := String(c.name)
			var is_cap := nm5.begins_with("Barrier_") or nm5.begins_with("NaturalEnd_")
			if nm5.begins_with("Barrier_"):
				n_bar += 1
				if not (c is StaticBody3D) or (c as StaticBody3D).collision_layer != 1:
					nat_col_ok = false
			elif nm5.begins_with("NaturalEnd_"):
				n_nat += 1
				if _collect_labels(c).size() != 0:
					nat_label_free = false
				if not (c is StaticBody3D) or (c as StaticBody3D).collision_layer != 1:
					nat_col_ok = false
			if is_cap:
				var zv := (c as Node3D).position.z
				if absf(zv - (s0m - 1.0)) < 0.01:
					cap_s0 += 1
				elif absf(zv - (s1m + 1.0)) < 0.01:
					cap_s1 += 1
				else:
					caps_z_ok = false
	var want_nat := 0
	var want_bar2 := 0
	for k in expect:
		if String(k) == "natural":
			want_nat += 1
		elif String(k) == "construction":
			want_bar2 += 1
	_check(n_nat == want_nat and n_bar == want_bar2,
		"%s: 端头构件 == ends (natural %d/%d, construction %d/%d)"
			% [label, n_nat, want_nat, n_bar, want_bar2])
	_check(nat_col_ok, label + ": 端头构件 layer1 + 实体碰撞")
	_check(nat_label_free, label + ": 自然端无 Label3D (非文字构件)")
	var want_cap_s0 := 0 if String(expect[0]) == "open" else 1
	var want_cap_s1 := 0 if String(expect[1]) == "open" else 1
	_check(caps_z_ok and cap_s0 == want_cap_s0 and cap_s1 == want_cap_s1,
		"%s: 端头 z 对位且 open 端无封 (s0端 %d/%d, s1端 %d/%d)"
			% [label, cap_s0, want_cap_s0, cap_s1, want_cap_s1])

	# 路名牌: 2 块 + 主行 == street.name (reported) + 方位词 (ai-drafted) + z 夹路面
	var rn2: Node = null
	if br:
		rn2 = br.get_node_or_null("RoadNames")
	_check(rn2 != null, label + ": RoadNames 容器存在")
	if rn2 != null:
		_check(rn2.get_child_count() == 2, "%s: 路名牌 2 块 (实际 %d)" % [label, rn2.get_child_count()])
		if rn2.get_child_count() == 2:
			var name_ok2 := true
			var dir_ok2 := true
			var plates2: Array = []
			for plate in rn2.get_children():
				plates2.append(plate)
				var pl2: Label3D = plate.get_node_or_null("StreetName")
				var dl2: Label3D = plate.get_node_or_null("DirHint")
				if pl2 == null or pl2.text != String(st.get("name", "")) \
						or String(pl2.get_meta("basis", "")) != "reported":
					name_ok2 = false
				if dl2 == null or String(dl2.get_meta("basis", "")) != "ai-drafted" \
						or not ["vers le Nord", "vers le Sud"].has(dl2.text):
					dir_ok2 = false
			_check(name_ok2, "%s: 路名主行 == street.name 且 basis reported (\"%s\")"
				% [label, String(st.get("name", ""))])
			_check(dir_ok2, "%s: 方位词 basis ai-drafted ∈ {Nord, Sud}" % label)
			plates2.sort_custom(func(a, b): return (a as Node3D).position.z < (b as Node3D).position.z)
			var z_s_want := clampf(s0m - 1.0 + 2.0, want_min + 1.0, want_max - 1.0)
			var z_n_want := clampf(s1m + 1.0 - 2.0, want_min + 1.0, want_max - 1.0)
			_check(absf((plates2[0] as Node3D).position.z - z_s_want) < 0.02 \
				and absf((plates2[1] as Node3D).position.z - z_n_want) < 0.02,
				"%s: 路名牌 z == 端点内缩并夹路面 [%.1f, %.1f] (实 [%.1f, %.1f])"
					% [label, z_s_want, z_n_want,
						(plates2[0] as Node3D).position.z, (plates2[1] as Node3D).position.z])

	# 铭牌容器 (内容 basis 由 rosiers 段与候选模式断言)
	var bsn: Node = null
	if br:
		bsn = br.get_node_or_null("BuildingSigns")
	_check(bsn != null, label + ": BuildingSigns 容器存在")


func _check(cond: bool, msg: String):
	if cond:
		print("[OK] ", msg)
	else:
		failures += 1
		print("[FAIL] ", msg)

func _quit():
	print("[StreetCheck] 失败数: ", failures)
	quit(failures)
