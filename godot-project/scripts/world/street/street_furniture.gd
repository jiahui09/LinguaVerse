extends RefCounted

const Planting := preload("res://scripts/world/street/planting.gd")

## 街景子系统 — 行道树 / 路灯 / 长椅 / 施工围栏 / 树池篦子 / 消防栓 / 垃圾桶 / 咖啡外摆
## (P2-A 自 street_generator._build_street_props 迁入; P3 批次5: 原语几何 → GLB 库)
##
## 所有权契约: 每子系统一个写入者; 避让策略调 planting.gd (唯一写入者)。
## 挂点: buildings_root/StreetProps → 装配器面数预算统计遍历 buildings_root 全部
##       子节点, 道具被自动覆盖; 建筑计数只看 Building_* 前缀, 不受影响。
## 碰撞层: 树/灯/椅/栓/桶/外摆 = 4 (装饰, 玩家撞 NPC 不撞); 围栏 = 1 (世界, 都撞)。
## 树位不自算 → 消费 planting.plan() (预算制计划), 保证树位与策略单一来源。
##
## GLB 库 (批次5, tools/blender-assets/build_props.py → artifacts/prop-glb → 过闸):
##   每实例挂子节点 (名 GLBModel 等) 并 set_meta("source_glb", res://…) —
##   street_check 据 meta 断言换装到位; GLB 缺失 → push_error + 无视觉 → 检查必红。
##   灯罩 "lamp_glow" 材质从 GLB 实例抓取 (导入 emission_strength=1.6, spawn 即置 0
##   = 白天), set_night_glow 驱动 emission_energy_multiplier — 对外语义与原语时代一致。
##   坐标: GLB 脚底在模型原点 (y=0), 实例落位即贴地, 无需偏移。
##
## 现场几何核对 (与 rosiers_layout.json, 迁移前头注释保留):
##   street.width=9.0 → 路面 x∈[-4.5,4.5]; street.backoff=6.0 → 人行道 x∈[4.5,6]
##   树/灯 x=±4.78: 树干外缘 4.89 < Pierre 占位内缘 4.95, 内缘 4.67 > 路缘 4.5
##   长椅 x=5.75 座面 5.525..5.975 < 6 (人行道外缘/建筑前脸)
##   新增点缀 (批次5): 垃圾桶 x=5.3 (灯旁), 消防栓 x=±4.78 (街端), 外摆 x=5.0 (门侧),
##   树池篦 0.56² 居树位 (外缘 [4.50,5.06] 恰齐路缘不入路面)。

const LAYER_WORLD := 1    # layer 1 值 1: 世界 (施工围栏, 玩家与 NPC 都撞)
const LAYER_DECOR := 4    # layer 3 值 4: 装饰道具 (树/灯/椅/栓/桶/外摆, 只有玩家撞)

const MODELS := {
	"lamp": "res://assets/models/street_lamp.glb",
	"tree": "res://assets/models/tree.glb",
	"bench": "res://assets/models/bench.glb",
	"barrier": "res://assets/models/barrier.glb",
	"planter": "res://assets/models/planter.glb",
	"bollard": "res://assets/models/bollard.glb",
	"grate": "res://assets/models/tree_grate.glb",
	"hydrant": "res://assets/models/hydrant.glb",
	"bin": "res://assets/models/trash_bin.glb",
	"bistro": "res://assets/models/bistro_set.glb",
}

const PARAMS := {
	"lamp_z": [-28.0, -14.0, 0.0, 14.0, 28.0],
	"bench_seats": [[5.75, 14.0], [5.75, -16.0], [-5.75, 6.0]],
	"lamp_light_rule": "i偶→-X侧, i奇→+X侧 (交替半数 5 盏真光源)",
	"pole_h": 4.2, "pole_r": 0.07,
	"trunk_h": 2.6, "trunk_r": 0.11,
	"lamp_head_size": 0.24,   # 遗留: GLB 化后仅作原语时代文档 (碰撞/槽位仍用 pole_*)
	"barrier_span": 13.0,    # 全宽跨到 |x|=6.5, 与建筑前脸搭接 0.5 堵死绕行
}

var _mats: Dictionary = {}              # 模块私有材质缓存 (按 key 复用)
var _lamp_head_mat: BaseMaterial3D      # 灯罩自发光 (GLB lamp_glow, set_night_glow 驱动)
var _lamp_lights: Array = []            # 带 OmniLight3D 的路灯 (交替侧, 约一半)
var _lamps: Array = []                  # 已生成灯位 [Vector2(x,z)] (新增点缀避让用)
var _benches: Array = []                # 已生成椅位 [Vector2(x,z)]

func params() -> Dictionary:
	return PARAMS

func param_hash() -> String:
	return str(PARAMS).sha256_text()

## 装配器调用: 生成 StreetProps 全部几何 (plan = planting.plan() 结果)
func build(gen, plan: Dictionary, min_s: float, max_s: float) -> void:
	if gen.buildings_root == null:
		return
	if gen.buildings_root.get_node_or_null("StreetProps") != null:
		return  # 幂等保护: 重复调用不重复生成
	# 槽位参数化 (P3 批次1): layout.street.slots 覆盖灯具/长椅槽位;
	# 无该字段 (Rosiers) → 全部走 PARAMS, 历史行为逐字节不变
	var slots: Dictionary = {}
	var st_raw = gen.layout.get("street")
	if st_raw is Dictionary:
		var sl_raw = (st_raw as Dictionary).get("slots")
		if sl_raw is Dictionary:
			slots = sl_raw
	var props := Node3D.new()
	props.name = "StreetProps"
	gen.buildings_root.add_child(props)  # 挂 buildings_root 下 → 面数预算统计覆盖
	# 避让参数与种植计划同源 (slots.planting 覆盖 → 无咖啡馆街区关闭幻影缓冲)
	var pp: Dictionary = Planting.PARAMS.duplicate(true)
	var pover: Dictionary = slots.get("planting", {})
	for k in pover:
		pp[k] = pover[k]
	_build_trees(gen, props, plan)
	_build_lamps(gen, props, slots, pp)
	_build_benches(gen, props, slots)
	_build_barriers(gen, props, min_s, max_s)
	_build_extras(gen, props, plan, slots, pp, min_s, max_s)
	print("[StreetFurniture] 街道道具完成: ", props.get_child_count(), " 个节点")

## 夜间半场: 灯头 emission + OmniLight 能量 (窗光部分留装配器)
func set_night_glow(factor: float) -> void:
	var v := clampf(factor, 0.0, 1.0)
	var energy := 0.0
	if v > 0.0:
		energy = 0.9 * clampf(v + 0.4, 0.0, 1.0)
	if _lamp_head_mat:
		_lamp_head_mat.emission_energy_multiplier = energy
	for entry in _lamp_lights:
		var ol := entry as OmniLight3D
		if ol and is_instance_valid(ol):
			ol.light_energy = energy

## ---------- 模块私有小工具 ----------

func _mat(key: String, color: Color, rough: float) -> StandardMaterial3D:
	if _mats.has(key):
		return _mats[key] as StandardMaterial3D
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	_mats[key] = m
	return m

## GLB 实例化并挂到 parent; 缺失 → push_error (street_check 断言 meta 在场 → 必红)
func _glb_instance(parent: Node3D, key: String, node_name: String) -> Node3D:
	var path: String = MODELS.get(key, "")
	if path.is_empty() or not ResourceLoader.exists(path):
		push_error("[StreetFurniture] 道具 GLB 缺失: %s" % path)
		return null
	var sc := load(path) as PackedScene
	if sc == null:
		push_error("[StreetFurniture] 道具 GLB 非 PackedScene: %s" % path)
		return null
	var inst := sc.instantiate() as Node3D
	if inst == null:
		push_error("[StreetFurniture] 道具 GLB 实例化失败: %s" % path)
		return null
	inst.name = node_name
	inst.set_meta("source_glb", path)
	parent.add_child(inst)
	return inst

## 从灯 GLB 实例抓 "lamp_glow" 表面材质 → set_night_glow 驱动 (全街共享同一资源)
func _grab_glow(node: Node) -> void:
	if _lamp_head_mat != null or node == null:
		return
	for child in node.get_children():
		_grab_glow(child)  # 递归 (GLB 结构可能多层)
	var mi := node as MeshInstance3D
	if mi == null or mi.mesh == null:
		return
	for s in mi.mesh.get_surface_count():
		var m: Material = mi.mesh.surface_get_material(s)
		if m == null:
			m = mi.get_surface_override_material(s)
		if m == null:
			continue
		var res := String(m.resource_name)
		if res == "lamp_glow" or (m is BaseMaterial3D and (m as BaseMaterial3D).emission_enabled):
			var bm := m as BaseMaterial3D
			bm.emission_enabled = true
			bm.emission_energy_multiplier = 0.0  # 白天; set_night_glow(factor>0) 驱动
			_lamp_head_mat = bm
			return

## 新增点缀避让: 距种植计划树位与已知灯/椅位 ≥ r
func _clear_of(x: float, z: float, r: float, plan: Dictionary, others: Array) -> bool:
	var p2 := Vector2(x, z)
	for pos in plan.get("positions", []):
		var d: Dictionary = pos
		if p2.distance_to(Vector2(float(d["x"]), float(d["z"]))) < r:
			return false
	for o in others:
		if (o as Vector2).distance_to(p2) < r:
			return false
	return true

## layout 端头 (z_end1 = min(s0)-1, z_end2 = max(s1)+1, 不硬编码)
func _street_ends(gen) -> Array:
	var s0_min := 1e9
	var s1_max := -1e9
	for b in gen.layout.get("buildings", []):
		s0_min = min(s0_min, float(b["s0"]))
		s1_max = max(s1_max, float(b["s1"]))
	return [s0_min - 1.0, s1_max + 1.0]

## ---------- a) 行道树 + 树池篦 (位置来自 planting 计划) ----------

func _build_trees(gen, props: Node3D, plan: Dictionary) -> void:
	var positions: Array = plan.get("positions", [])
	for i in positions.size():
		var p: Dictionary = positions[i]
		_spawn_tree(gen, props, float(p["x"]), float(p["z"]), i)

func _spawn_tree(gen, props: Node3D, x: float, z: float, idx: int) -> void:
	var tree := StaticBody3D.new()
	tree.name = "Tree_%d" % idx
	tree.collision_layer = LAYER_DECOR  # 装饰层: 玩家撞, NPC 不撞
	tree.collision_mask = 0
	# GLB 悬铃木 (批次5, 132 面): 锥台干 + 三球冠; 冠层向街心略探是自然树形
	_glb_instance(tree, "tree", "GLBModel")
	# 树池铁篦 (0.56², 贴人行道; 树 x=4.78 → 外缘 [4.50,5.06] 恰齐路缘)
	_glb_instance(tree, "grate", "GLBGrate")
	# 碰撞: 树干圆柱 (半径 0.11 → 外缘 4.89 < Pierre 内缘 4.95, 内缘 4.67 > 路缘 4.5)
	gen._add_cyl_shape(tree, float(PARAMS["trunk_r"]), float(PARAMS["trunk_h"]), Vector3(0, 1.3, 0))
	tree.position = Vector3(x, 0, z)
	props.add_child(tree)

## ---------- b) 路灯 ----------

func _build_lamps(gen, props: Node3D, slots: Dictionary, pp: Dictionary) -> void:
	var n := 0
	var lamp_z: Array = slots.get("lamp_z", PARAMS["lamp_z"])
	var px := float(Planting.PARAMS["prop_x"])
	for i in lamp_z.size():
		var z: float = float(lamp_z[i])
		for side_v in [1.0, -1.0]:
			var side := float(side_v)
			if Planting.blocked(side, z, pp) != "":
				continue
			# 交替半数装真光源: i 偶 → -X 侧, i 奇 → +X 侧
			var with_light: bool = (i % 2 == 0 and side < 0.0) or (i % 2 == 1 and side > 0.0)
			_spawn_lamp(gen, props, side * px, z, n, with_light)
			n += 1

## ---------- c) 长椅 ----------

func _build_benches(gen, props: Node3D, slots: Dictionary) -> void:
	# 三个位置的核对 (迁移前头注释保留, 对应默认槽位):
	#  (5.75, 14): 座面 5.525..5.975 < 6; 与 +X 路灯(4.78,14) 通道 0.675 > 玩家直径 0.6
	#  (5.75,-16): 距 Jean 12.3m > 1.6; 座面与 -X 树不重叠
	#  (-5.75, 6): Pierre 占位 vs 座面间隙 0.075 不接触
	var seats: Array = slots.get("bench_seats", PARAMS["bench_seats"])
	for i in seats.size():
		var s: Array = seats[i]
		_spawn_bench(gen, props, float(s[0]), float(s[1]), i)

func _spawn_lamp(gen, props: Node3D, x: float, z: float, idx: int, with_light: bool) -> void:
	var lamp := StaticBody3D.new()
	lamp.name = "Lamp_%d" % idx
	lamp.collision_layer = LAYER_DECOR  # 装饰层: 玩家撞, NPC 不撞
	lamp.collision_mask = 0
	# GLB 巴黎街灯 (批次5, 156 面): 配重柱身 + 六棱灯罩; 灯罩 lamp_glow → 夜间驱动
	var model := _glb_instance(lamp, "lamp", "GLBModel")
	_grab_glow(model)
	# 碰撞: 杆体圆柱 (尺寸与原语一致; 外缘 4.85 < Pierre 内缘 4.95)
	gen._add_cyl_shape(lamp, float(PARAMS["pole_r"]), float(PARAMS["pole_h"]), Vector3(0, 2.1, 0))
	if with_light:
		var ol := OmniLight3D.new()
		ol.light_color = Color(1.0, 0.85, 0.6)
		ol.light_energy = 0.0   # 白天 0; set_night_glow(factor>0) → 0.9*clamp(factor+0.4,0,1)
		ol.omni_range = 14.0
		ol.shadow_enabled = false
		ol.position = Vector3(0, 4.1, 0)
		lamp.add_child(ol)
		_lamp_lights.append(ol)
	lamp.position = Vector3(x, 0, z)
	_lamps.append(Vector2(x, z))
	props.add_child(lamp)

func _spawn_bench(gen, props: Node3D, x: float, z: float, idx: int) -> void:
	var bench := StaticBody3D.new()
	bench.name = "Bench_%d" % idx
	bench.collision_layer = LAYER_DECOR  # 装饰层: 玩家撞, NPC 不撞
	bench.collision_mask = 0
	bench.position = Vector3(x, 0, z)
	if x < 0.0:
		bench.rotation_degrees = Vector3(0, 180.0, 0)  # -X 椅翻面, 靠背朝建筑
	# GLB 条板长椅 (批次5, 192 面): 5 座板+3 背板+铸铁腿; 靠背朝局部 +x (建筑侧)
	_glb_instance(bench, "bench", "GLBModel")
	# 碰撞: 座面+靠背整体一盒 (0.45 × 0.85 × 1.6, 与原语一致)
	gen._add_box_shape(bench, Vector3(0.45, 0.85, 1.6), Vector3(0, 0.425, 0))
	_benches.append(Vector2(x, z))
	props.add_child(bench)

## ---------- d) 施工围栏 (决策 11 自然边界) ----------

func _build_barriers(gen, props: Node3D, min_s: float, max_s: float) -> void:
	var ends := _street_ends(gen)
	# P3 批次2 (决策 11/30): street.ends 分派 — open 端不封 (跨街走通),
	# natural 端 → 花坛+护柱自然边界 (无文字), construction/缺省 → 施工围栏 (历史行为)
	var kinds: Array = ["construction", "construction"]
	var st_end = gen.layout.get("street")
	if st_end is Dictionary and (st_end as Dictionary).get("ends") is Array:
		var ek: Array = (st_end as Dictionary)["ends"]
		for i in 2:
			if i < ek.size():
				kinds[i] = String(ek[i])
	for i in ends.size():
		# 防御: 夹回已生成路面范围 (min_s/max_s 含 ±14 外扩)
		var z := clampf(float(ends[i]), min_s + 1.0, max_s - 1.0)
		match String(kinds[i]):
			"open":
				pass  # 开放端: 街道在此延续, 不设封阻
			"natural":
				_spawn_natural_end(gen, props, z, i)
			_:
				_spawn_barrier(gen, props, z, i)

func _spawn_barrier(gen, props: Node3D, z: float, idx: int) -> void:
	var bar := StaticBody3D.new()
	bar.name = "Barrier_%d" % idx
	bar.collision_layer = LAYER_WORLD  # 层 1: 世界, 玩家与 NPC 都撞
	bar.collision_mask = 1
	bar.position = Vector3(0, 0, z)
	# GLB 施工围栏 (批次5, 252 面): 3 横杆+13 红白条+A 腿+白标牌 (盒内)
	_glb_instance(bar, "barrier", "GLBModel")
	var label := Label3D.new()
	label.text = "Travaux — Détour"
	label.font_size = 48
	label.outline_size = 8
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.modulate = Color(0.80, 0.14, 0.11)      # 红字
	label.outline_modulate = Color(0.96, 0.96, 0.94)  # 白描边
	# pixel_size 0.003 → 字高 ≈0.14m, 16 字符宽 ≈1.1m, 落在 1.2m 标牌内
	label.pixel_size = 0.003
	label.no_depth_test = true  # 避免被自己的标牌盒挡住 (billboard 会转到盒内)
	label.position = Vector3(0, 1.05, 0.0)
	# 文字 basis 分级 (P2-A): 施工文案为生成器字面量, 非源数据 → ai-drafted
	label.set_meta("basis", "ai-drafted")
	label.set_meta("text_source", "generator_literal")
	bar.add_child(label)
	# 整宽碰撞一盒: x∈[-6.5,6.5], y∈[0,1.1], 层 1
	gen._add_box_shape(bar, Vector3(float(PARAMS["barrier_span"]), 1.1, 0.35), Vector3(0, 0.55, 0.0))
	props.add_child(bar)

## 自然端 (决策 11): 花坛带 + 护柱, 封堵但不带文字 (basis 规则 = 无 Label3D)
## 3 段花坛 4.3 宽连续铺满 x∈[-6.45,6.45] (与建筑前脸 |x|=6 搭接 → 堵死绕行),
## GLB 石槽含灌木冠; 碰撞整宽一盒 (层 1, 玩家与 NPC 都撞)。
func _spawn_natural_end(gen, props: Node3D, z: float, idx: int) -> void:
	var end := StaticBody3D.new()
	end.name = "NaturalEnd_%d" % idx
	end.collision_layer = LAYER_WORLD
	end.collision_mask = 1
	end.position = Vector3(0, 0, z)
	for px_v in [-4.3, 0.0, 4.3]:
		# GLB 花坛石槽 4.3 × 0.55 高 × 0.9 深 + 灌木三团 (批次5, 168 面)
		var pl := _glb_instance(end, "planter", "GLBPlanter")
		if pl:
			pl.position = Vector3(float(px_v), 0, 0)
	# 石质护柱 ×4 (花坛接缝与两端; GLB 84 面, 高 1.10)
	for px_v in [-6.3, -2.15, 2.15, 6.3]:
		var bo := _glb_instance(end, "bollard", "GLBBollard")
		if bo:
			bo.position = Vector3(float(px_v), 0, 0)
	# 无文字: 自然边界不挂 Label3D (street_check 断言 Label3D 缺席)
	gen._add_box_shape(end, Vector3(13.0, 1.2, 0.9), Vector3(0, 0.6, 0.0))
	props.add_child(end)

## ---------- e) 新增点缀 (P3 批次5): 垃圾桶 / 消防栓 / 咖啡外摆 ----------

func _build_extras(gen, props: Node3D, plan: Dictionary, slots: Dictionary,
		pp: Dictionary, min_s: float, max_s: float) -> void:
	var lamp_z: Array = slots.get("lamp_z", PARAMS["lamp_z"])
	# a) 垃圾桶: 每 3 个灯槽取一 (i%3==0), +X 侧灯杆旁 (x=5.3, 同 z);
	#    只避让树位与长椅 — 与成对灯杆 0.52m 净距是设计位 (灯杆旁分类桶)
	var n_bin := 0
	for i in lamp_z.size():
		if i % 3 != 0:
			continue
		var z := float(lamp_z[i])
		if Planting.blocked(1.0, z, pp) != "":
			continue
		if not _clear_of(5.3, z, 1.2, plan, _benches):
			continue
		_spawn_bin(gen, props, 5.3, z, n_bin)
		n_bin += 1
	# b) 消防栓: 街道两端各一 (交替侧), 距端头 4m 且夹回路面范围
	var ends := _street_ends(gen)
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		var z2: float = float(ends[i]) + (4.0 if i == 0 else -4.0)
		z2 = clampf(z2, min_s + 3.0, max_s - 3.0)
		if not _clear_of(side * 4.78, z2, 1.5, plan, _lamps + _benches):
			continue
		_spawn_hydrant(gen, props, side * 4.78, z2, i)
	# c) 咖啡外摆: 仅 cafe_anchor 街 (Rosiers); 桌 flank 门口 ±2.1m,
	#    中间 z∈[3.7,5.0] 留 1.3m 门径; 桌心 x = backoff-1.0 (贴前脸不入路面)
	var cafe_raw = gen.layout.get("cafe_anchor")
	var cafe: Dictionary = cafe_raw if cafe_raw is Dictionary else {}
	if cafe.is_empty():
		return
	var side3 := 1.0 if float(cafe.get("side", 1)) >= 0.0 else -1.0
	var backoff := float((gen.layout.get("street") as Dictionary).get("backoff", 6.0))
	var s := float(cafe.get("s", 0.0))
	var n_tab := 0
	for dz_v in [-2.1, 2.1]:
		var tx := side3 * (backoff - 1.0)
		var tz := s + float(dz_v)
		if not _clear_of(tx, tz, 1.4, plan, _lamps + _benches):
			continue
		_spawn_bistro(gen, props, tx, tz, n_tab)
		n_tab += 1

func _spawn_bin(gen, props: Node3D, x: float, z: float, idx: int) -> void:
	var bin := StaticBody3D.new()
	bin.name = "Bin_%d" % idx
	bin.collision_layer = LAYER_DECOR
	bin.collision_mask = 0
	_glb_instance(bin, "bin", "GLBModel")   # 绿桶 0.78m 高 (112 面)
	gen._add_cyl_shape(bin, 0.18, 0.78, Vector3(0, 0.39, 0))
	bin.position = Vector3(x, 0, z)
	props.add_child(bin)

func _spawn_hydrant(gen, props: Node3D, x: float, z: float, idx: int) -> void:
	var hy := StaticBody3D.new()
	hy.name = "Hydrant_%d" % idx
	hy.collision_layer = LAYER_DECOR
	hy.collision_mask = 0
	_glb_instance(hy, "hydrant", "GLBModel")   # 红栓 0.80m 高 (120 面)
	gen._add_cyl_shape(hy, 0.13, 0.8, Vector3(0, 0.4, 0))
	hy.position = Vector3(x, 0, z)
	props.add_child(hy)

func _spawn_bistro(gen, props: Node3D, x: float, z: float, idx: int) -> void:
	var tab := StaticBody3D.new()
	tab.name = "Bistro_%d" % idx
	tab.collision_layer = LAYER_DECOR
	tab.collision_mask = 0
	_glb_instance(tab, "bistro", "GLBModel")   # 石圆桌+2椅 (220 面), 椅沿 z 朝外
	# 碰撞一盒罩桌椅整体 (0.9 × 0.85 × 2.85): 外摆不许穿模, 门口走线在两桌之间
	gen._add_box_shape(tab, Vector3(0.9, 0.85, 2.85), Vector3(0, 0.425, 0))
	tab.position = Vector3(x, 0, z)
	props.add_child(tab)
