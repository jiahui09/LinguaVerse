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

func _ready():
	load_layout()
	build_all()
	print("[StreetGenerator] 生成完成: ", buildings_root.get_child_count(), " 栋建筑, 街长 ", int(street_length_m), "m")

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

## 夜间窗户亮灯 (night_glow 联动)
## @param factor 0=白天 1=深夜; 由外部(昼夜循环)驱动
func set_night_glow(factor: float):
	var v := clampf(factor, 0.0, 1.0)
	for key in _facade_mats:
		var m := _facade_mats[key] as ShaderMaterial
		if m:
			m.set_shader_parameter("night_glow", v)

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
