extends Node3D

## 巴黎街景生成器 — 读取布局 JSON, 程序化生成完整街道
##
## 坐标约定:
##   - 街道沿 Z 轴延伸(s 里程 → z), 咖啡馆在 z≈0
##   - side=+1 建筑在 +X 侧, side=-1 在 -X 侧
##   - 建筑前立面距街中线 = backoff(布局 street.backoff)
##   - 每个建筑节点原点 = 前立面中心(临街面, y=0)
##   - 内部子节点: 墙身伸向街区内(side*depth/2), 立面贴前表面
##
## 每栋建筑:
##   StaticBody3D (碰撞) + BodyBox(奶白墙身) + RoofBox(锌灰顶)
##   + FacadeBox(0.12 薄盒, 窗户 Shader 贴前表面)
## 咖啡馆(is_cafe): 生成 CafeSite 占位(含碰撞与可见占位盒), S4 用 glb 替换
##
## 碰撞层约定 (collision_layer 位值):
##   layer 1 (值 1) = 世界: 路面 / 人行道 / 建筑 / 咖啡馆 / 施工围栏 — 玩家与 NPC 都撞
##   layer 2 (值 2) = NPC
##   layer 3 (值 4) = 装饰道具 (行道树 / 路灯 / 长椅) — 玩家撞
##                    (main.tscn 里 Player 的 collision_mask = 5 = 1|4),
##                    NPC 不撞 (NPC 场景 collision_mask 恒为 1, 否则 Pierre 每帧
##                    强制 position.x = walk_x 会被装饰物卡住抖动)
##
## 街道道具 (_build_street_props, 决策 11 自然边界 + 街道家具):
##   全部代码建节点(MeshInstance3D + StaticBody3D + CollisionShape3D + StandardMaterial3D),
##   低多边形、不加载外部资源; 统一挂在 buildings_root 下的 "StreetProps" 节点
##   (面数预算统计遍历 buildings_root 全部子节点 → 道具被覆盖;
##    建筑计数与碰撞检查只看 Building_* 开头子节点 → 不受影响)

@export var layout_path: String = "res://data/layouts/rosiers_layout.json"

var layout: Dictionary = {}

var _wall_base: Color = Color(0.955, 0.925, 0.87)
var _wall_mats: Array = []
var _roof_mat: StandardMaterial3D
var _road_mat: StandardMaterial3D
var _sidewalk_mat: StandardMaterial3D
var _facade_shader: Shader
var _facade_mats: Dictionary = {}

var cafe_site: Node3D = null
var buildings_root: Node3D
var street_length_m: float = 160.0

# 街道道具状态 (见头注释"碰撞层约定")
var _prop_mats: Dictionary = {}          # 道具共享材质 (按 key 复用)
var _lamp_head_mat: StandardMaterial3D   # 灯头自发光材质 (set_night_glow 驱动)
var _lamp_lights: Array = []             # 带 OmniLight3D 的路灯 (交替侧, 约一半)

func _ready():
	load_layout()
	build_all()
	# 建筑计数只看 Building_* 开头的子节点 (StreetProps/CafeSite 不计入)
	var n_buildings := 0
	if buildings_root:
		for c in buildings_root.get_children():
			if String(c.name).begins_with("Building_"):
				n_buildings += 1
	print("[StreetGenerator] 生成完成: ", n_buildings, " 栋建筑, 街长 ", int(street_length_m), "m")

func load_layout():
	var f = FileAccess.open(layout_path, FileAccess.READ)
	if f == null:
		push_error("[StreetGenerator] 无法打开布局文件: ", layout_path)
		return
	var parsed = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("[StreetGenerator] 布局 JSON 解析失败")
		return
	layout = parsed

func build_all():
	if layout.is_empty():
		return
	_build_materials()

	var min_s = 1e9
	var max_s = -1e9
	for b in layout.get("buildings", []):
		min_s = min(min_s, float(b["s0"]))
		max_s = max(max_s, float(b["s1"]))
	min_s -= 14.0
	max_s += 14.0
	street_length_m = max_s - min_s

	buildings_root = Node3D.new()
	buildings_root.name = "Buildings"
	add_child(buildings_root)

	_build_road(min_s, max_s)
	_build_sidewalks(min_s, max_s)
	_build_street_props(min_s, max_s)  # 行道树/路灯/长椅/施工围栏 (决策 11)
	_build_all_buildings()
	_build_cafe_site()

## ---------- 材质 ----------

func _build_materials():
	for i in 8:
		var m = StandardMaterial3D.new()
		var f = 1.0 + (float(i) - 3.5) * 0.03
		m.albedo_color = Color(_wall_base.r * f, _wall_base.g * f, _wall_base.b * f)
		m.roughness = 0.92
		_wall_mats.append(m)
	_roof_mat = StandardMaterial3D.new()
	_roof_mat.albedo_color = Color(0.30, 0.30, 0.33)
	_roof_mat.roughness = 0.7
	_road_mat = StandardMaterial3D.new()
	_road_mat.albedo_color = Color(0.44, 0.42, 0.40)
	_road_mat.roughness = 0.95
	_sidewalk_mat = StandardMaterial3D.new()
	_sidewalk_mat.albedo_color = Color(0.72, 0.70, 0.67)
	_sidewalk_mat.roughness = 0.9
	_facade_shader = load("res://shaders/facade.gdshader")

func _get_facade_material(levels: int, wpf: int, shop: bool, seed_f: float) -> ShaderMaterial:
	var key := "%d_%d_%d" % [levels, wpf, int(shop)]
	if _facade_mats.has(key):
		return _facade_mats[key]
	var m = ShaderMaterial.new()
	m.shader = _facade_shader
	m.set_shader_parameter("levels", levels)
	m.set_shader_parameter("windows_per_floor", wpf)
	m.set_shader_parameter("ground_shop", shop)
	_facade_mats[key] = m
	return m

## ---------- 路面/人行道 ----------

func _build_road(min_s: float, max_s: float):
	var width = float(layout["street"].get("width", 9.0))
	var road := StaticBody3D.new()
	road.name = "Road"
	road.collision_layer = 1
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(width, 0.12, max_s - min_s)
	mi.mesh = box
	mi.material_override = _road_mat
	mi.position = Vector3(0, -0.06, (min_s + max_s) / 2.0)
	road.add_child(mi)
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(width, 0.5, max_s - min_s)
	col.shape = shape
	col.position = Vector3(0, -0.25, (min_s + max_s) / 2.0)
	road.add_child(col)
	add_child(road)

func _build_sidewalks(min_s: float, max_s: float):
	var width = float(layout["street"].get("width", 9.0))
	var backoff = float(layout["street"].get("backoff", 6.0))
	var sw_w = backoff - width / 2.0
	if sw_w <= 0.0:
		return
	for side in [1.0, -1.0]:
		var sw := StaticBody3D.new()
		sw.name = "Sidewalk" if side > 0 else "SidewalkM"
		sw.collision_layer = 1
		var cx = side * (width / 2.0 + sw_w / 2.0)
		var mi := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(sw_w, 0.14, max_s - min_s)
		mi.mesh = box
		mi.material_override = _sidewalk_mat
		mi.position = Vector3(cx, -0.07, (min_s + max_s) / 2.0)
		sw.add_child(mi)
		var col := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = Vector3(sw_w, 0.6, max_s - min_s)
		col.shape = shape
		col.position = Vector3(cx, -0.3, (min_s + max_s) / 2.0)
		sw.add_child(col)
		add_child(sw)

## ---------- 街道道具 (行道树 / 路灯 / 长椅 / 施工围栏) ----------
##
## 现场几何 (与 rosiers_layout.json 核对):
##   street.width=9.0 → 路面 x∈[-4.5,4.5]; street.backoff=6.0 → 人行道 x∈[4.5,6]
##   建筑前脸 |x|=6 (facade 薄盒中心 5.91 → x∈[5.85,5.97], 无碰撞)
##   cafe_anchor side=+1 s=4.34 → 咖啡馆门口世界坐标 (5.4, 0, 4.34)
##   Pierre 沿 x=-5.2 来回 (胶囊半径 0.25 → 占位 x∈[-5.45,-4.95], z∈[-18,18])
##   Jean 站 (5.5, 0, -3.66); 玩家出生 (0,0,-22), 已验证路径: 沿街到咖啡馆门口
##
## 核心 x 边界算术 (树/灯统一用 x=±4.78):
##   树干半径 0.11 → 外缘 4.78+0.11 = 4.89 < 4.95 (Pierre 占位内缘, -X 侧 -4.89 > -4.95)
##   树干内缘 4.78-0.11 = 4.67 > 4.5 (路缘) → 路面 |x|<4.5 全空, 出生点→门口路径不被堵
##   灯杆半径 0.07 → 外缘 4.85 < 4.95, 同样不侵入 Pierre 巡游带
##   长椅 x=5.75 座面进深 0.45 → 5.525..5.975 < 6 (人行道外缘/建筑前脸)

const LAYER_WORLD := 1    # layer 1 值 1: 世界 (施工围栏用, 玩家与 NPC 都撞)
const LAYER_DECOR := 4    # layer 3 值 4: 装饰道具 (树/路灯/长椅, 只有玩家撞)

const PROP_X := 4.78              # 树/灯 x (算术见上)
const TREE_Z_FROM := -30.0        # 树 z 起点
const TREE_Z_STEP := 12.0         # 树间距
const TREE_Z_COUNT := 6           # -30, -18, -6, 6, 18, 30
const LAMP_Z: Array = [-28.0, -14.0, 0.0, 14.0, 28.0]
const CAFE_DOOR_Z := 4.34         # 咖啡馆门口 z (= cafe_anchor.s, side=+1)
const DOOR_CLEAR_M := 3.5         # 门口缓冲半径
const JEAN_X := 5.5
const JEAN_Z := -3.66
const PROP_CLEAR_M := 1.6         # 道具与 Jean 的最小距离

## 生成全部街道道具 (幂等: 已存在 StreetProps 则直接返回)
func _build_street_props(min_s: float, max_s: float):
	if buildings_root == null:
		return
	if buildings_root.get_node_or_null("StreetProps") != null:
		return  # 幂等保护: 重复调用不重复生成
	var props := Node3D.new()
	props.name = "StreetProps"
	buildings_root.add_child(props)  # 挂在 buildings_root 下 → 面数预算统计覆盖道具
	_build_prop_trees(props)
	_build_prop_lamps(props)
	_build_prop_benches(props)
	_build_prop_barriers(props, min_s, max_s)
	print("[StreetGenerator] 街道道具完成: ", props.get_child_count(), " 个节点")

## ---------- 道具小工具 ----------

func _prop_mat(key: String, color: Color, rough: float) -> StandardMaterial3D:
	if _prop_mats.has(key):
		return _prop_mats[key] as StandardMaterial3D
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	_prop_mats[key] = m
	return m

## 灯头自发光材质 (白天 emission=0, set_night_glow 驱动)
func _lamp_head_material() -> StandardMaterial3D:
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

func _box_mesh(w: float, h: float, d: float) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = Vector3(w, h, d)
	return b

func _add_mesh(parent: Node3D, mesh: Mesh, mat: Material, pos: Vector3, rot_deg: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation_degrees = rot_deg
	parent.add_child(mi)
	return mi

func _add_box_shape(parent: Node3D, size: Vector3, pos: Vector3):
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	col.position = pos
	parent.add_child(col)

func _add_cyl_shape(parent: Node3D, radius: float, height: float, pos: Vector3):
	var col := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = radius
	shape.height = height
	col.shape = shape
	col.position = pos
	parent.add_child(col)

## +X 侧道具避让: 咖啡馆门口 3.5m 缓冲 + 距 Jean 1.6m
func _avoid_cafe_side(side: float, z: float) -> bool:
	if side <= 0.0:
		return false  # 咖啡馆与 Jean 都在 +X 侧
	if absf(z - CAFE_DOOR_Z) < DOOR_CLEAR_M:
		return true
	if Vector2(side * PROP_X, z).distance_to(Vector2(JEAN_X, JEAN_Z)) < PROP_CLEAR_M:
		return true
	return false

## ---------- a) 行道树 ----------

func _build_prop_trees(props: Node3D):
	var bark := _prop_mat("bark", Color(0.33, 0.25, 0.19), 0.95)
	var leaf := _prop_mat("leaf", Color(0.37, 0.44, 0.35), 0.85)  # 灰绿
	var n := 0
	for i in TREE_Z_COUNT:
		var z := TREE_Z_FROM + float(i) * TREE_Z_STEP
		for side_v in [1.0, -1.0]:
			var side := float(side_v)
			if _avoid_cafe_side(side, z):
				continue
			_spawn_tree(props, side * PROP_X, z, n, bark, leaf)
			n += 1

func _spawn_tree(props: Node3D, x: float, z: float, idx: int, bark: Material, leaf: Material):
	var tree := StaticBody3D.new()
	tree.name = "Tree_%d" % idx
	tree.collision_layer = LAYER_DECOR  # 装饰层: 玩家撞, NPC 不撞
	tree.collision_mask = 0
	# 树干: 低模圆柱 (radius 0.11, height 2.6, radial 8)
	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.11
	trunk.bottom_radius = 0.11
	trunk.height = 2.6
	trunk.radial_segments = 8
	_add_mesh(tree, trunk, bark, Vector3(0, 1.3, 0))
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
		_add_mesh(tree, s, leaf, crown_pos[ci] as Vector3)
	# 碰撞: 树干圆柱 (半径 0.11 → 外缘 4.89 < Pierre 内缘 4.95, 内缘 4.67 > 路缘 4.5)
	_add_cyl_shape(tree, 0.11, 2.6, Vector3(0, 1.3, 0))
	tree.position = Vector3(x, 0, z)
	props.add_child(tree)

## ---------- b) 路灯 ----------

func _build_prop_lamps(props: Node3D):
	var metal := _prop_mat("lamp_metal", Color(0.20, 0.21, 0.23), 0.6)
	var head := _lamp_head_material()
	var n := 0
	for i in LAMP_Z.size():
		var z: float = LAMP_Z[i]
		for side_v in [1.0, -1.0]:
			var side := float(side_v)
			if _avoid_cafe_side(side, z):
				continue
			# 核对门口缓冲: 5 个 z 里离 4.34 最近的是 z=0 → |0-4.34| = 4.34 > 3.5 → 一个都不用跳过
			# 距 Jean: 最近的 z=0 → sqrt(0.72^2 + 3.66^2) = 3.73 > 1.6 → 也不跳过 → 共 10 盏
			# 只给约一半装真光源 (5 盏, 交替侧): i 偶数 → -X 侧, i 奇数 → +X 侧
			var with_light: bool = (i % 2 == 0 and side < 0.0) or (i % 2 == 1 and side > 0.0)
			_spawn_lamp(props, side * PROP_X, z, n, with_light, metal, head)
			n += 1

func _spawn_lamp(props: Node3D, x: float, z: float, idx: int, with_light: bool, metal: Material, head: Material):
	var lamp := StaticBody3D.new()
	lamp.name = "Lamp_%d" % idx
	lamp.collision_layer = LAYER_DECOR  # 装饰层: 玩家撞, NPC 不撞
	lamp.collision_mask = 0
	# 灯杆 (radius 0.07, height 4.2, radial 8)
	var pole := CylinderMesh.new()
	pole.top_radius = 0.07
	pole.bottom_radius = 0.07
	pole.height = 4.2
	pole.radial_segments = 8
	_add_mesh(lamp, pole, metal, Vector3(0, 2.1, 0))
	# 灯头小盒 (自发光材质, set_night_glow 驱动 emission)
	_add_mesh(lamp, _box_mesh(0.24, 0.16, 0.24), head, Vector3(0, 4.28, 0))
	# 碰撞: 杆体圆柱 (外缘 4.85 < Pierre 内缘 4.95)
	_add_cyl_shape(lamp, 0.07, 4.2, Vector3(0, 2.1, 0))
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

## ---------- c) 长椅 ----------

func _build_prop_benches(props: Node3D):
	var wood := _prop_mat("bench_wood", Color(0.44, 0.30, 0.17), 0.85)  # 木棕色
	# 三个位置的核对:
	#  (5.75, 14): 座面 x∈[5.525,5.975], 靠背外沿 5.975 < 6 (人行道外缘); 与 +X 路灯(4.78,14)
	#      同 z 但灯杆外缘 4.85 → 通道 5.525-4.85 = 0.675 > 玩家直径 0.6, 可通行不重叠
	#  (5.75,-16): 距 Jean(5.5,-3.66) = 12.3m > 1.6; 座面 z∈[-16.8,-15.2] 与 +X 树(z=-18) 不重叠
	#  (-5.75, 6): Pierre 占位 x∈[-5.45,-4.95] vs 座面 x∈[-5.975,-5.525] → 间隙 0.075 不接触
	#      且 Pierre 的 mask=1 不感知 layer 4; 与 -X 树(-4.78,6) 间隙 5.525-4.89 = 0.635 不重叠
	var seats: Array = [Vector2(5.75, 14.0), Vector2(5.75, -16.0), Vector2(-5.75, 6.0)]
	for i in seats.size():
		var p := seats[i] as Vector2
		_spawn_bench(props, p.x, p.y, i, wood)

func _spawn_bench(props: Node3D, x: float, z: float, idx: int, wood: Material):
	var bench := StaticBody3D.new()
	bench.name = "Bench_%d" % idx
	bench.collision_layer = LAYER_DECOR  # 装饰层: 玩家撞, NPC 不撞
	bench.collision_mask = 0
	bench.position = Vector3(x, 0, z)
	if x < 0.0:
		bench.rotation_degrees = Vector3(0, 180.0, 0)  # -X 椅翻面, 靠背朝建筑
	# 座面 1.6(沿街 z) × 0.08(厚) × 0.45(进深 x)
	_add_mesh(bench, _box_mesh(0.45, 0.08, 1.6), wood, Vector3(0, 0.45, 0))
	# 靠背 (局部 +x = 朝建筑一侧; 外沿 0.225 → 世界 5.975 < 6)
	_add_mesh(bench, _box_mesh(0.08, 0.4, 1.6), wood, Vector3(0.185, 0.65, 0))
	# 两条腿
	for d_v in [1.0, -1.0]:
		var d := float(d_v)
		_add_mesh(bench, _box_mesh(0.45, 0.45, 0.08), wood, Vector3(0, 0.225, d * 0.7))
	# 碰撞: 座面+靠背整体一盒 (0.45 × 0.85 × 1.6)
	_add_box_shape(bench, Vector3(0.45, 0.85, 1.6), Vector3(0, 0.425, 0))
	props.add_child(bench)

## ---------- d) 施工围栏 (决策 11 自然边界) ----------

func _build_prop_barriers(props: Node3D, min_s: float, max_s: float):
	# 端点取自 layout: z_end1 = min(s0)-1, z_end2 = max(s1)+1 (不硬编码)
	var s0_min := 1e9
	var s1_max := -1e9
	for b in layout.get("buildings", []):
		s0_min = min(s0_min, float(b["s0"]))
		s1_max = max(s1_max, float(b["s1"]))
	var ends: Array = [s0_min - 1.0, s1_max + 1.0]
	for i in ends.size():
		# 防御: 夹回已生成路面范围 (min_s/max_s 含 ±14 外扩)
		var z := clampf(float(ends[i]), min_s + 1.0, max_s - 1.0)
		_spawn_barrier(props, z, i)

func _spawn_barrier(props: Node3D, z: float, idx: int):
	var red := _prop_mat("barrier_red", Color(0.80, 0.14, 0.11), 0.7)
	var white := _prop_mat("barrier_white", Color(0.93, 0.93, 0.90), 0.7)
	var frame := _prop_mat("barrier_frame", Color(0.74, 0.71, 0.65), 0.8)

	var bar := StaticBody3D.new()
	bar.name = "Barrier_%d" % idx
	bar.collision_layer = LAYER_WORLD  # 层 1: 世界, 玩家与 NPC 都撞
	bar.collision_mask = 1
	bar.position = Vector3(0, 0, z)

	# 3 根横杆: 全宽 13.0 → x∈[-6.5,6.5], 与 |x|=6 建筑前脸搭接 0.5 → 堵死同层绕行
	for yy in [0.30, 0.70, 1.05]:
		_add_mesh(bar, _box_mesh(13.0, 0.10, 0.08), frame, Vector3(0, float(yy), 0.0))
	# 红白相间分段条纹: 13 段 × 1.0m = 全宽 13.0, 两种材质交替小盒
	for i in 13:
		var sx := -6.0 + float(i)
		var mat: Material = red if i % 2 == 0 else white
		_add_mesh(bar, _box_mesh(1.0, 0.28, 0.05), mat, Vector3(sx, 0.50, 0.0))
	# A 形支腿: 两组 (x=±5.2), 每组前后各一腿, 顶点汇合于 y≈1.11, 落点 z=±0.41
	for lx_v in [5.2, -5.2]:
		var lx := float(lx_v)
		for d_v in [1.0, -1.0]:
			var d := float(d_v)
			_add_mesh(bar, _box_mesh(0.09, 1.2, 0.09), frame,
				Vector3(lx, 0.55, d * 0.205), Vector3(-20.0 * d, 0.0, 0.0))
	# 标牌 1.2 × 0.8 (挂在围栏上沿, 中心 y=1.05 → 0.65..1.45, 围栏本体高 ≈1.1)
	# 红/白配色: 白底标牌盒 + Label3D 红字白描边
	_add_mesh(bar, _box_mesh(1.2, 0.8, 0.06), white, Vector3(0, 1.05, 0.0))
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
	bar.add_child(label)
	# 整宽碰撞一盒: x∈[-6.5,6.5], y∈[0,1.1], 层 1
	_add_box_shape(bar, Vector3(13.0, 1.1, 0.35), Vector3(0, 0.55, 0.0))
	props.add_child(bar)

## ---------- 建筑 ----------

func _build_all_buildings():
	var backoff = float(layout["street"].get("backoff", 6.0))
	var cafe: Dictionary = layout.get("cafe_anchor", {})
	# 咖啡馆占位: 模型沿街约 7.2m(局部 x ±3.6 → 世界 z ±3.6), 排除同侧重叠建筑
	var cafe_side := -99.0
	var cafe_s := 0.0
	if not cafe.is_empty():
		cafe_side = float(cafe.get("side", 1))
		cafe_s = float(cafe.get("s", 0.0))
	var clear_half := 6.0
	for b in layout.get("buildings", []):
		if b.get("is_cafe", false):
			continue
		if not cafe.is_empty() and float(b["side"]) == cafe_side:
			var b_mid := (float(b["s0"]) + float(b["s1"])) / 2.0
			if abs(b_mid - cafe_s) < clear_half:
				continue  # 与咖啡馆模型重叠区, 跳过
		_build_one_building(b, backoff)

func _seed_from_id(idn: int) -> float:
	return float((idn * 2654435761) & 0xFFFF) / 65535.0

func _build_one_building(b: Dictionary, backoff: float):
	var side = 1.0 if float(b["side"]) >= 0.0 else -1.0
	var s_mid = (float(b["s0"]) + float(b["s1"])) / 2.0
	var along_w = max(2.0, float(b["s1"]) - float(b["s0"]))
	var depth = max(3.0, float(b.get("depth", 12.0)))
	var height = max(4.0, float(b.get("height", 19.2)))
	var levels = int(b.get("levels", 6))
	var idn = int(b.get("id", 0))
	var seed_f = _seed_from_id(idn)

	# 节点原点 = 前立面中心
	var body := StaticBody3D.new()
	body.name = "Building_%d" % idn
	body.collision_layer = 1
	body.collision_mask = 1
	body.position = Vector3(side * backoff, 0, s_mid)

	# 墙身(街区方向伸 depth)
	var wall_mi := MeshInstance3D.new()
	var wbox := BoxMesh.new()
	wbox.size = Vector3(depth, height, along_w)
	wall_mi.mesh = wbox
	var wmat := StandardMaterial3D.new()
	wmat.albedo_color = _wall_mats[int(seed_f * float(_wall_mats.size())) % _wall_mats.size()].albedo_color
	wmat.roughness = 0.92
	wall_mi.material_override = wmat
	wall_mi.position = Vector3(side * depth / 2.0, height / 2.0, 0)
	body.add_child(wall_mi)

	# 屋顶锌灰(前表面起, 略探出)
	var roof_mi := MeshInstance3D.new()
	var rbox := BoxMesh.new()
	rbox.size = Vector3(depth + 0.4, 0.6, along_w + 0.5)
	roof_mi.mesh = rbox
	roof_mi.material_override = _roof_mat
	roof_mi.position = Vector3(side * (depth / 2.0 + 0.05), height, 0)
	body.add_child(roof_mi)

	# 临街立面(窗户 shader 薄盒, 位于前表面 x≈0 稍向街)
	var n_wpf = max(1, int(round(along_w / 2.8)))
	var facade_mi := MeshInstance3D.new()
	var fbox := BoxMesh.new()
	fbox.size = Vector3(0.12, height, along_w)
	facade_mi.mesh = fbox
	facade_mi.material_override = _get_facade_material(levels, n_wpf, true, seed_f)
	# 薄盒中心: 前表面(side*backoff处,x=0)向街外探 0.06
	facade_mi.position = Vector3(-side * 0.09, height / 2.0, 0)
	body.add_child(facade_mi)

	# 碰撞(整墙身)
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(depth, height, along_w)
	col.shape = shape
	col.position = Vector3(side * depth / 2.0, height / 2.0, 0)
	body.add_child(col)

	buildings_root.add_child(body)

## ---------- 咖啡馆 ----------
## 模型(cafe.glb): 门面在模型局部 z≈0 面朝 +Z, 内部向 -Z(吧台 z≈-6.5)
## 街道布置: side=+1 时门面须朝 -X(面向 x=0 街中) → 绕 Y 旋转 -90°

const CAFE_GLB := "res://assets/models/cafe.glb"

func _build_cafe_site():
	var cafe: Dictionary = layout.get("cafe_anchor", {})
	if cafe.is_empty():
		return
	var side = 1.0 if float(cafe.get("side", 1)) >= 0.0 else -1.0
	var backoff = float(layout["street"].get("backoff", 6.0))
	var s = float(cafe.get("s", 0.0))

	cafe_site = Node3D.new()
	cafe_site.name = "CafeSite"
	# 旋转: 门面(局部+z)转到街中(-x) → yaw=-90°(局部+z→世界-x)
	cafe_site.rotation_degrees = Vector3(0, -90.0 * side, 0)
	cafe_site.position = Vector3(side * backoff, 0, s)

	# 1) 加载 glb 模型
	var glb_scene: PackedScene = load(CAFE_GLB)
	if glb_scene:
		var inst := glb_scene.instantiate() as Node3D
		inst.name = "CafeModel"
		cafe_site.add_child(inst)

		# 2) 碰撞体(模型局部坐标, 与 mesh 同系)
		var body := StaticBody3D.new()
		body.name = "CafeCollision"
		body.collision_layer = 1
		# 墙体碰撞: 模型局部 AABB x[-3.7,3.5] y[0,8.15] z[-8.2,1.25]
		_add_box(body, Vector3(0.45, 8.0, 7.0), Vector3(-3.6, 4.0, -3.8))  # 左墙
		_add_box(body, Vector3(0.45, 8.0, 7.0), Vector3(3.45, 4.0, -3.8))   # 右墙
		_add_box(body, Vector3(7.0, 8.0, 0.45), Vector3(0.0, 4.0, -8.0))    # 后墙
		# 门面左右段(中央门洞 1.6m 留空可走入)
		_add_box(body, Vector3(1.55, 8.0, 0.5), Vector3(-2.3, 4.0, 0.15))   # 门面左
		_add_box(body, Vector3(1.55, 8.0, 0.5), Vector3(2.3, 4.0, 0.15))    # 门面右
		# 二层面板(装饰, 挡住看穿屋顶内)
		_add_box(body, Vector3(6.8, 0.3, 6.8), Vector3(0.0, 3.6, -3.8))
		# 室内地板(glb Floor 仅视觉, 补碰撞层防跌落; 门洞处仍可走进)
		_add_box(body, Vector3(7.0, 0.25, 8.2), Vector3(0.0, -0.15, -3.8))
		# 吧台(靠后墙, 玩家不可穿越, 留两侧绕行)
		_add_box(body, Vector3(3.6, 1.3, 0.6), Vector3(0.0, 0.65, -5.9))
		# 甜品柜
		_add_box(body, Vector3(1.0, 1.0, 0.6), Vector3(-1.6, 0.5, -5.8))
		cafe_site.add_child(body)
	else:
		push_error("[StreetGenerator] 加载咖啡馆模型失败: ", CAFE_GLB)

	buildings_root.add_child(cafe_site)

func _add_box(body: StaticBody3D, size: Vector3, pos: Vector3):
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	col.position = pos
	body.add_child(col)

## 夜间窗户亮灯 + 路灯联动 (night_glow 联动)
## @param factor 0=白天 1=深夜; 由外部(昼夜循环)驱动
##   factor > 0  → 窗户夜光 + 路灯亮 (energy = 0.9*clamp(factor+0.4, 0, 1), 灯头 emission 同步)
##   factor == 0 → 窗户夜光灭 + 路灯 energy = 0 (白天)
##   日落时昼夜循环把 factor 提到 0.35/0.75 → 路灯自动亮起
func set_night_glow(factor: float):
	var v := clampf(factor, 0.0, 1.0)
	for key in _facade_mats:
		var m := _facade_mats[key] as ShaderMaterial
		if m:
			m.set_shader_parameter("night_glow", v)
	# 路灯: 灯头 emission + OmniLight 能量
	var energy := 0.0
	if v > 0.0:
		energy = 0.9 * clampf(v + 0.4, 0.0, 1.0)
	if _lamp_head_mat:
		_lamp_head_mat.emission_energy_multiplier = energy
	for entry in _lamp_lights:
		var ol := entry as OmniLight3D
		if ol and is_instance_valid(ol):
			ol.light_energy = energy

## 供外部查询: 咖啡馆门面朝向(玩家走进门位置, 世界坐标)
func get_cafe_door_pos() -> Vector3:
	if cafe_site == null:
		return Vector3.ZERO
	var door := cafe_site.global_position
	# 门在模型局部 x≈0(门洞中心); 朝街一侧外推 0.6m
	var local := Vector3(0.0, 0.0, 0.6)
	var door_world := cafe_site.global_transform * local
	door = door_world
	door.y = 0.0
	return door

## 咖啡馆吧台前位置(玩家站立对话点)
func get_cafe_staff_pos() -> Vector3:
	if cafe_site == null:
		return Vector3.ZERO
	# 吧台在模型局部 (0, 0.9, -5.9); NPC 站吧台后
	var local := Vector3(0.0, 0.0, -6.3)
	return cafe_site.global_transform * local
