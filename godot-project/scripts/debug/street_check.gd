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

	# 围栏位置: 布局端点 s0-1 / s1+1 (与生成端同式, 防硬编码漂移)
	var s0_min := 1e9
	var s1_max := -1e9
	for b in layout_buildings:
		s0_min = min(s0_min, float(b["s0"]))
		s1_max = max(s1_max, float(b["s1"]))
	var bar_zs: Array = []
	for bk in barriers:
		if bk is Node3D:
			bar_zs.append((bk as Node3D).position.z)
	bar_zs.sort()
	var ends_ok := bar_zs.size() == 2
	if ends_ok:
		ends_ok = absf(float(bar_zs[0]) - (s0_min - 1.0)) < 0.01 \
			and absf(float(bar_zs[1]) - (s1_max + 1.0)) < 0.01
	_check(ends_ok, "围栏 z == 布局端点 (s0−1=%.1f, s1+1=%.1f)" % [s0_min - 1.0, s1_max + 1.0])

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
	var bar_basis := false
	for bk in barriers:
		for lab in _collect_labels(bk as Node):
			if String((lab as Label3D).get_meta("basis", "")) == "ai-drafted":
				bar_basis = true
	_check(bar_basis, "围栏施工文案 basis == ai-drafted")
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


func _check(cond: bool, msg: String):
	if cond:
		print("[OK] ", msg)
	else:
		failures += 1
		print("[FAIL] ", msg)

func _quit():
	print("[StreetCheck] 失败数: ", failures)
	quit(failures)
