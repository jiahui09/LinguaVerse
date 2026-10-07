extends RefCounted

const Planting := preload("res://scripts/world/street/planting.gd")

## 街景子系统 — 行道树 / 路灯 / 长椅 / 施工围栏
## (P2-A 自 street_generator._build_street_props 迁入)
##
## 所有权契约: 每子系统一个写入者; 避让策略调 planting.gd (唯一写入者)。
## 挂点: buildings_root/StreetProps → 装配器面数预算统计遍历 buildings_root 全部
##       子节点, 道具被自动覆盖; 建筑计数只看 Building_* 前缀, 不受影响。
## 碰撞层: 树/灯/椅 = 4 (装饰, 玩家撞 NPC 不撞); 围栏 = 1 (世界, 都撞)。
## 树位不自算 → 消费 planting.plan() (预算制计划), 保证树位与策略单一来源。
##
## 现场几何核对 (与 rosiers_layout.json, 迁移前头注释保留):
##   street.width=9.0 → 路面 x∈[-4.5,4.5]; street.backoff=6.0 → 人行道 x∈[4.5,6]
##   树/灯 x=±4.78: 树干外缘 4.89 < Pierre 占位内缘 4.95, 内缘 4.67 > 路缘 4.5
##   长椅 x=5.75 座面 5.525..5.975 < 6 (人行道外缘/建筑前脸)

const LAYER_WORLD := 1    # layer 1 值 1: 世界 (施工围栏, 玩家与 NPC 都撞)
const LAYER_DECOR := 4    # layer 3 值 4: 装饰道具 (树/灯/椅, 只有玩家撞)

const PARAMS := {
	"lamp_z": [-28.0, -14.0, 0.0, 14.0, 28.0],
	"bench_seats": [[5.75, 14.0], [5.75, -16.0], [-5.75, 6.0]],
	"lamp_light_rule": "i偶→-X侧, i奇→+X侧 (交替半数 5 盏真光源)",
	"pole_h": 4.2, "pole_r": 0.07,
	"trunk_h": 2.6, "trunk_r": 0.11,
	"lamp_head_size": 0.24,
	"barrier_span": 13.0,    # 全宽跨到 |x|=6.5, 与建筑前脸搭接 0.5 堵死绕行
}

var _mats: Dictionary = {}              # 模块私有材质缓存 (按 key 复用)
var _lamp_head_mat: StandardMaterial3D  # 灯头自发光 (set_night_glow 驱动)
var _lamp_lights: Array = []            # 带 OmniLight3D 的路灯 (交替侧, 约一半)

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
	var props := Node3D.new()
	props.name = "StreetProps"
	gen.buildings_root.add_child(props)  # 挂 buildings_root 下 → 面数预算统计覆盖
	_build_trees(gen, props, plan)
	_build_lamps(gen, props)
	_build_benches(gen, props)
	_build_barriers(gen, props, min_s, max_s)
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

## 灯头自发光材质 (白天 emission=0, set_night_glow 驱动)
func _head_mat() -> StandardMaterial3D:
	if _lamp_head_mat != null:
		return _lamp_head_mat
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.92, 0.86, 0.68)
	m.roughness = 0.4
	m.emission_enabled = true
	m.emission = Color(1.0, 0.85, 0.6)
	m.emission_energy_multiplier = 0.0
	_lamp_head_mat = m
	return m

## ---------- a) 行道树 (位置来自 planting 计划) ----------

func _build_trees(gen, props: Node3D, plan: Dictionary) -> void:
	var bark := _mat("bark", Color(0.33, 0.25, 0.19), 0.95)
	var leaf := _mat("leaf", Color(0.37, 0.44, 0.35), 0.85)  # 灰绿
	var positions: Array = plan.get("positions", [])
	for i in positions.size():
		var p: Dictionary = positions[i]
		_spawn_tree(gen, props, float(p["x"]), float(p["z"]), i, bark, leaf)

func _spawn_tree(gen, props: Node3D, x: float, z: float, idx: int, bark: Material, leaf: Material):
	var tree := StaticBody3D.new()
	tree.name = "Tree_%d" % idx
	tree.collision_layer = LAYER_DECOR  # 装饰层: 玩家撞, NPC 不撞
	tree.collision_mask = 0
	# 树干: 低模圆柱 (radius 0.11, height 2.6, radial 8)
	var trunk := CylinderMesh.new()
	trunk.top_radius = float(PARAMS["trunk_r"])
	trunk.bottom_radius = float(PARAMS["trunk_r"])
	trunk.height = float(PARAMS["trunk_h"])
	trunk.radial_segments = 8
	gen._add_mesh(tree, trunk, bark, Vector3(0, 1.3, 0))
	# 树冠: 3 个低模球 (radial 10 ≤12, ring 5 ≤6, 半径 0.75-0.95)
	# 冠层向街心略探出 (local x 负方向) 是自然树形; 碰撞只有树干 → 路面 |x|<4.5 仍全空
	var crown_pos: Array = [Vector3(0.0, 3.2, 0.0), Vector3(-0.45, 3.0, 0.3), Vector3(0.4, 3.5, -0.2)]
	var crown_r: Array = [0.95, 0.75, 0.8]
	for ci in crown_pos.size():
		var s := SphereMesh.new()
		s.radius = float(crown_r[ci])
		s.height = float(crown_r[ci]) * 2.0
		s.radial_segments = 10
		s.rings = 5
		gen._add_mesh(tree, s, leaf, crown_pos[ci] as Vector3)
	# 碰撞: 树干圆柱 (半径 0.11 → 外缘 4.89 < Pierre 内缘 4.95, 内缘 4.67 > 路缘 4.5)
	gen._add_cyl_shape(tree, float(PARAMS["trunk_r"]), float(PARAMS["trunk_h"]), Vector3(0, 1.3, 0))
	tree.position = Vector3(x, 0, z)
	props.add_child(tree)

## ---------- b) 路灯 ----------

func _build_lamps(gen, props: Node3D) -> void:
	var metal := _mat("lamp_metal", Color(0.20, 0.21, 0.23), 0.6)
	var head := _head_mat()
	var n := 0
	var lamp_z: Array = PARAMS["lamp_z"]
	var px := float(Planting.PARAMS["prop_x"])
	for i in lamp_z.size():
		var z: float = float(lamp_z[i])
		for side_v in [1.0, -1.0]:
			var side := float(side_v)
			if Planting.blocked(side, z, Planting.PARAMS) != "":
				continue
			# 交替半数装真光源: i 偶 → -X 侧, i 奇 → +X 侧
			var with_light: bool = (i % 2 == 0 and side < 0.0) or (i % 2 == 1 and side > 0.0)
			_spawn_lamp(gen, props, side * px, z, n, with_light, metal, head)
			n += 1

## ---------- c) 长椅 ----------

func _build_benches(gen, props: Node3D) -> void:
	var wood := _mat("bench_wood", Color(0.44, 0.30, 0.17), 0.85)  # 木棕色
	# 三个位置的核对 (迁移前头注释保留):
	#  (5.75, 14): 座面 5.525..5.975 < 6; 与 +X 路灯(4.78,14) 通道 0.675 > 玩家直径 0.6
	#  (5.75,-16): 距 Jean 12.3m > 1.6; 座面与 -X 树不重叠
	#  (-5.75, 6): Pierre 占位 vs 座面间隙 0.075 不接触
	var seats: Array = PARAMS["bench_seats"]
	for i in seats.size():
		var s: Array = seats[i]
		_spawn_bench(gen, props, float(s[0]), float(s[1]), i, wood)

func _spawn_lamp(gen, props: Node3D, x: float, z: float, idx: int, with_light: bool, metal: Material, head: Material):
	var lamp := StaticBody3D.new()
	lamp.name = "Lamp_%d" % idx
	lamp.collision_layer = LAYER_DECOR  # 装饰层: 玩家撞, NPC 不撞
	lamp.collision_mask = 0
	# 灯杆 (radius 0.07, height 4.2, radial 8)
	var pole := CylinderMesh.new()
	pole.top_radius = float(PARAMS["pole_r"])
	pole.bottom_radius = float(PARAMS["pole_r"])
	pole.height = float(PARAMS["pole_h"])
	pole.radial_segments = 8
	gen._add_mesh(lamp, pole, metal, Vector3(0, 2.1, 0))
	# 灯头小盒 (自发光材质, set_night_glow 驱动 emission)
	var hs := float(PARAMS["lamp_head_size"])
	gen._add_mesh(lamp, gen._box_mesh(hs, 0.16, hs), head, Vector3(0, 4.28, 0))
	# 碰撞: 杆体圆柱 (外缘 4.85 < Pierre 内缘 4.95)
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
	props.add_child(lamp)

func _spawn_bench(gen, props: Node3D, x: float, z: float, idx: int, wood: Material):
	var bench := StaticBody3D.new()
	bench.name = "Bench_%d" % idx
	bench.collision_layer = LAYER_DECOR  # 装饰层: 玩家撞, NPC 不撞
	bench.collision_mask = 0
	bench.position = Vector3(x, 0, z)
	if x < 0.0:
		bench.rotation_degrees = Vector3(0, 180.0, 0)  # -X 椅翻面, 靠背朝建筑
	# 座面 1.6(沿街 z) × 0.08(厚) × 0.45(进深 x)
	gen._add_mesh(bench, gen._box_mesh(0.45, 0.08, 1.6), wood, Vector3(0, 0.45, 0))
	# 靠背 (局部 +x = 朝建筑一侧; 外沿 0.225 → 世界 5.975 < 6)
	gen._add_mesh(bench, gen._box_mesh(0.08, 0.4, 1.6), wood, Vector3(0.185, 0.65, 0))
	# 两条腿
	for d_v in [1.0, -1.0]:
		var d := float(d_v)
		gen._add_mesh(bench, gen._box_mesh(0.45, 0.45, 0.08), wood, Vector3(0, 0.225, d * 0.7))
	# 碰撞: 座面+靠背整体一盒 (0.45 × 0.85 × 1.6)
	gen._add_box_shape(bench, Vector3(0.45, 0.85, 1.6), Vector3(0, 0.425, 0))
	props.add_child(bench)

## ---------- d) 施工围栏 (决策 11 自然边界) ----------

func _build_barriers(gen, props: Node3D, min_s: float, max_s: float) -> void:
	# 端点取自 layout: z_end1 = min(s0)-1, z_end2 = max(s1)+1 (不硬编码)
	var s0_min := 1e9
	var s1_max := -1e9
	for b in gen.layout.get("buildings", []):
		s0_min = min(s0_min, float(b["s0"]))
		s1_max = max(s1_max, float(b["s1"]))
	var ends: Array = [s0_min - 1.0, s1_max + 1.0]
	for i in ends.size():
		# 防御: 夹回已生成路面范围 (min_s/max_s 含 ±14 外扩)
		var z := clampf(float(ends[i]), min_s + 1.0, max_s - 1.0)
		_spawn_barrier(gen, props, z, i)

func _spawn_barrier(gen, props: Node3D, z: float, idx: int):
	var red := _mat("barrier_red", Color(0.80, 0.14, 0.11), 0.7)
	var white := _mat("barrier_white", Color(0.93, 0.93, 0.90), 0.7)
	var frame := _mat("barrier_frame", Color(0.74, 0.71, 0.65), 0.8)

	var bar := StaticBody3D.new()
	bar.name = "Barrier_%d" % idx
	bar.collision_layer = LAYER_WORLD  # 层 1: 世界, 玩家与 NPC 都撞
	bar.collision_mask = 1
	bar.position = Vector3(0, 0, z)

	var span := float(PARAMS["barrier_span"])
	# 3 根横杆: 全宽 13.0 → x∈[-6.5,6.5], 与 |x|=6 建筑前脸搭接 0.5 → 堵死同层绕行
	for yy in [0.30, 0.70, 1.05]:
		gen._add_mesh(bar, gen._box_mesh(span, 0.10, 0.08), frame, Vector3(0, float(yy), 0.0))
	# 红白相间分段条纹: 13 段 × 1.0m = 全宽 13.0, 两种材质交替小盒
	for i in 13:
		var sx := -6.0 + float(i)
		var mat: Material = red if i % 2 == 0 else white
		gen._add_mesh(bar, gen._box_mesh(1.0, 0.28, 0.05), mat, Vector3(sx, 0.50, 0.0))
	# A 形支腿: 两组 (x=±5.2), 每组前后各一腿, 顶点汇合于 y≈1.11, 落点 z=±0.41
	for lx_v in [5.2, -5.2]:
		var lx := float(lx_v)
		for d_v in [1.0, -1.0]:
			var d := float(d_v)
			gen._add_mesh(bar, gen._box_mesh(0.09, 1.2, 0.09), frame,
				Vector3(lx, 0.55, d * 0.205), Vector3(-20.0 * d, 0.0, 0.0))
	# 标牌 1.2 × 0.8 (挂在围栏上沿, 中心 y=1.05 → 0.65..1.45, 围栏本体高 ≈1.1)
	# 红/白配色: 白底标牌盒 + Label3D 红字白描边
	gen._add_mesh(bar, gen._box_mesh(1.2, 0.8, 0.06), white, Vector3(0, 1.05, 0.0))
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
	gen._add_box_shape(bar, Vector3(span, 1.1, 0.35), Vector3(0, 0.55, 0.0))
	props.add_child(bar)
