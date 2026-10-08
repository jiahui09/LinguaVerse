extends Node3D

## 巴黎街景生成器 — 装配器 (P2-A 拆分后: 集成者独占)
##
## 职责: 读布局 JSON → 建共享材质 → 串行装配 scripts/world/street/ 子系统
##       → 生成建筑与咖啡馆 → 对外暴露布局/门面 API。
##
## 子系统 (每模块一个写入者; 跨界改动经本装配器串行接入):
##   road_surface.gd     路面 / 人行道
##   planting.gd         预算制种植计划 (纯函数, 避让策略唯一写入者)
##   street_furniture.gd 树/灯/椅/围栏几何 + 夜灯半场 (消费 planting 计划)
##   building_signs.gd   建筑铭牌 + Label3D 文字 basis 分级
##   road_names.gd       路名牌 + 方位词
## 共享几何工具 (_box_mesh/_add_mesh/_add_box_shape/_add_cyl_shape) 与资产清单
## 留在本装配器 — 工具的单一写入者 = 集成者; 子系统跨界调用 gen._add_*。
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
##   layer 3 (值 4) = 装饰道具 (行道树 / 路灯 / 长椅 / 路名牌柱) — 玩家撞
##                    (main.tscn 里 Player 的 collision_mask = 5 = 1|4),
##                    NPC 不撞 (NPC 场景 collision_mask 恒为 1, 否则 Pierre 每帧
##                    强制 position.x = walk_x 会被装饰物卡住抖动)
##
## 面数预算: 统计遍历 buildings_root 全部子节点 → 子系统容器 (StreetProps /
##   BuildingSigns / RoadNames) 挂在其下被自动覆盖; 建筑计数只看 Building_* 前缀。

const RoadSurface := preload("res://scripts/world/street/road_surface.gd")
const StreetPlanting := preload("res://scripts/world/street/planting.gd")
const StreetFurniture := preload("res://scripts/world/street/street_furniture.gd")
const BuildingSigns := preload("res://scripts/world/street/building_signs.gd")
const RoadNames := preload("res://scripts/world/street/road_names.gd")

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

# 子系统实例 (装配后持有; 夜光联动与街区清单走这里)
var _road_surface = null
var _planting = null
var _furniture = null
var _building_signs = null
var _road_names = null

func _ready():
	load_layout()
	build_all()
	# 建筑计数只看 Building_* 开头的子节点 (子系统容器与 CafeSite 不计入)
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

	# ── P2-A 子系统装配 (scripts/world/street/, 每模块一个写入者, 串行接入) ──
	_road_surface = RoadSurface.new()
	_road_surface.build(self, min_s, max_s)
	_planting = StreetPlanting.new()
	_furniture = StreetFurniture.new()
	# 槽位参数化 (P3 批次1): layout.street.slots.planting 覆盖种植网格;
	# 无该字段 (Rosiers) → plan_with 只吃 PARAMS, 历史行为逐字节不变
	var plant_over: Dictionary = {}
	var st_raw = layout.get("street")
	if st_raw is Dictionary and (st_raw as Dictionary).has("slots"):
		var sl_raw = (st_raw as Dictionary).get("slots")
		if sl_raw is Dictionary and (sl_raw as Dictionary).has("planting"):
			plant_over = (sl_raw as Dictionary)["planting"]
	_furniture.build(self, StreetPlanting.plan_with(StreetPlanting.PARAMS, plant_over), min_s, max_s)
	_building_signs = BuildingSigns.new()
	_building_signs.build(self)
	_road_names = RoadNames.new()
	_road_names.build(self, min_s, max_s)

	_build_all_buildings()
	_build_cafe_site()

## ---------- 街区清单 (assets_manifest.json 街区级 entry) ----------

## 三方核对口径: 清单记录 == 磁盘文件 == 运行时重算 (street_check 断言)。
## layout sha256 对文件字节 (sha256_text = UTF-8 字节 == 磁盘字节);
## 子系统 param_hash = str(PARAMS).sha256_text(), 参数变 → 哈希变 → 断言报失,
## 须由集成者有意更新清单 (哈希绑定失效纪律)。
func get_block_manifest() -> Dictionary:
	var f := FileAccess.open(layout_path, FileAccess.READ)
	var layout_bytes := 0
	var layout_sha := ""
	if f:
		layout_bytes = f.get_length()
		layout_sha = f.get_as_text().sha256_text()
	return {
		"layout": {"path": layout_path, "bytes": layout_bytes, "sha256": layout_sha},
		"subsystems": {
			"road_surface": _param_hash_of(_road_surface),
			"street_furniture": _param_hash_of(_furniture),
			"planting": _param_hash_of(_planting),
			"building_signs": _param_hash_of(_building_signs),
			"road_names": _param_hash_of(_road_names),
		},
	}

func _param_hash_of(mod) -> String:
	if mod == null or not mod.has_method("param_hash"):
		return ""
	return String(mod.param_hash())

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

## ---------- 共享几何工具 (子系统跨界调用 gen._add_*) ----------

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

## ---------- 建筑 ----------

func _build_all_buildings():
	var backoff = float(layout["street"].get("backoff", 6.0))
	# cafe_anchor 可为 null (无咖啡馆街区, 如 Place des Vosges by_v 布局)
	var cafe_raw = layout.get("cafe_anchor")
	var cafe: Dictionary = cafe_raw if cafe_raw is Dictionary else {}
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

## 立面前表面离中线的无符号距离。摆楼/挂牌等子系统统一从这里取位, 不各自算:
## - backoff 模式 (V1 默认, 布局无 placement 字段): 舞台布景模型, 盒紧贴人行道;
## - by_v 模式 (广场/宽街): OSM 真实投影 |v| − depth/2, 夹取不小于 backoff,
##   保证窄街布局行为与历史字节级一致。
func get_facade_face(b: Dictionary) -> float:
	var backoff := float(layout["street"].get("backoff", 6.0))
	if String(layout["street"].get("placement", "backoff")) != "by_v":
		return backoff
	var v := absf(float(b.get("v", 0.0)))
	var d := maxf(3.0, float(b.get("depth", 12.0)))
	return maxf(backoff, v - d / 2.0)

func _build_one_building(b: Dictionary, backoff: float):
	var side = 1.0 if float(b["side"]) >= 0.0 else -1.0
	var s_mid = (float(b["s0"]) + float(b["s1"])) / 2.0
	var along_w = max(2.0, float(b["s1"]) - float(b["s0"]))
	var depth = max(3.0, float(b.get("depth", 12.0)))
	var height = max(4.0, float(b.get("height", 19.2)))
	var levels = int(b.get("levels", 6))
	var idn = int(b.get("id", 0))
	var seed_f = _seed_from_id(idn)

	# 节点原点 = 前立面中心 (by_v 布局时立面按 OSM 真实投影, 见 get_facade_face)
	var body := StaticBody3D.new()
	body.name = "Building_%d" % idn
	body.collision_layer = 1
	body.collision_mask = 1
	body.position = Vector3(side * get_facade_face(b), 0, s_mid)

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
	var cafe_raw = layout.get("cafe_anchor")
	var cafe: Dictionary = cafe_raw if cafe_raw is Dictionary else {}
	if cafe.is_empty():
		return
	var side = 1.0 if float(cafe.get("side", 1)) >= 0.0 else -1.0
	var backoff = float(layout["street"].get("backoff", 6.0))
	var s = float(cafe.get("s", 0.0))

	cafe_site = Node3D.new()
	cafe_site.name = "CafeSite"
	# 文字 basis 分级 (P2-A): 店名来自 OSM name 标签 (data/osm/rosiers_full.json)
	cafe_site.set_meta("basis", "reported")
	cafe_site.set_meta("text_source", "osm_name")
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
## 窗户部分在本装配器 (材质缓存 _facade_mats); 路灯部分委托 street_furniture。
func set_night_glow(factor: float):
	var v := clampf(factor, 0.0, 1.0)
	for key in _facade_mats:
		var m := _facade_mats[key] as ShaderMaterial
		if m:
			m.set_shader_parameter("night_glow", v)
	if _furniture != null:
		_furniture.set_night_glow(v)

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
