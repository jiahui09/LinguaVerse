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
var _curb_mat: StandardMaterial3D            # P3 批次4: 路缘石花岗岩带
var _manhole_albedo: Texture2D               # P3 批次4: 井盖贴片
var _manhole_normal: Texture2D
var _facade_shader: Shader
var _facade_mats: Dictionary = {}
var _facade_albedo: Texture2D               # P3 批次6: 墙身拉毛贴图 (传给 shader)
var _facade_normal: Texture2D
var _door_mat: StandardMaterial3D           # P3 批次6: 立面细节材质
var _trim_mat: StandardMaterial3D
var _pipe_mat: StandardMaterial3D
var _chimney_mat: StandardMaterial3D
var _iron_mat: StandardMaterial3D
var _awning_mats: Array = []

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
	_apply_placement()
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

## P3 批次2 (决策 30): 多街同场景世界接缝 — meta.placement {ref, ref_axis, x, z}
## 在**参考街的游戏空间**里直链接缝 (装配为直线展开模型, ENU 不作位移源):
##   position = (x, 0, z); rotation.y = my_axis − ref_axis (轴角差定朝向)。
## 无 placement (Rosiers 等单街/参考街) → 恒等变换, 历史行为不变。
func _apply_placement():
	var meta = layout.get("meta", {})
	if not (meta is Dictionary):
		return
	var pl = (meta as Dictionary).get("placement", {})
	if not (pl is Dictionary) or (pl as Dictionary).is_empty():
		return
	var ref_axis := float((pl as Dictionary).get("ref_axis", 0.0))
	var my_axis := float((meta as Dictionary).get("street_axis_deg", 0.0))
	position = Vector3(float((pl as Dictionary).get("x", 0.0)), 0.0,
		float((pl as Dictionary).get("z", 0.0)))
	rotation.y = deg_to_rad(my_axis - ref_axis)
	print("[StreetGenerator] 世界接缝: pos=", position,
		" rot_y=", rad_to_deg(rotation.y), "° ref=", (pl as Dictionary).get("ref", "?"))

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
	# P3 批次2: street.ends — open 端吃 road_limits (s0 端夹至链起, s1 端止于链止);
	# legacy (无 ends) → 行为逐字节不变 (±14 外扩)
	var st_raw_road = layout.get("street")
	if st_raw_road is Dictionary:
		var ends_raw = (st_raw_road as Dictionary).get("ends", [])
		var rl_raw = (st_raw_road as Dictionary).get("road_limits", [])
		if ends_raw is Array and rl_raw is Array and rl_raw.size() >= 2:
			if String(ends_raw[0]) == "open":
				min_s = maxf(min_s, float(rl_raw[0]))
			if String(ends_raw[1]) == "open":
				max_s = float(rl_raw[1])  # 止于链止 (投影钳制保证链止 ≥ s1, 不再 +14 外扩)
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
	_build_landmarks()

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
		# P3 批次6: 墙身石灰拉毛贴图 (世界三平面, 跨楼无缝)
		_apply_texture_family(m, "facade", 1.6, m.albedo_color, 0.92)
		_wall_mats.append(m)
	_roof_mat = StandardMaterial3D.new()
	_roof_mat.albedo_color = Color(0.30, 0.30, 0.33)
	_roof_mat.roughness = 0.7
	_road_mat = StandardMaterial3D.new()
	_apply_texture_family(_road_mat, "cobble", 2.0, Color(0.98, 0.97, 0.95), 0.95)
	_sidewalk_mat = StandardMaterial3D.new()
	_apply_texture_family(_sidewalk_mat, "paving", 1.6, Color(1.0, 0.99, 0.97), 0.9)
	_curb_mat = StandardMaterial3D.new()
	_apply_texture_family(_curb_mat, "granite", 1.0, Color(0.96, 0.96, 0.97), 0.85)
	_manhole_albedo = _load_texture("manhole_albedo")
	_manhole_normal = _load_texture("manhole_normal")
	_facade_albedo = _load_texture("facade_albedo")
	_facade_normal = _load_texture("facade_normal")
	_facade_shader = load("res://shaders/facade.gdshader")
	# P3 批次6: 立面成套细节材质
	_door_mat = StandardMaterial3D.new()
	_door_mat.albedo_color = Color(0.24, 0.17, 0.11)
	_door_mat.roughness = 0.65
	_trim_mat = StandardMaterial3D.new()
	_trim_mat.albedo_color = Color(0.87, 0.85, 0.80)
	_trim_mat.roughness = 0.8
	_pipe_mat = StandardMaterial3D.new()
	_pipe_mat.albedo_color = Color(0.55, 0.56, 0.58)
	_pipe_mat.roughness = 0.45
	_pipe_mat.metallic = 0.3
	_chimney_mat = StandardMaterial3D.new()
	_chimney_mat.albedo_color = Color(0.55, 0.33, 0.24)
	_chimney_mat.roughness = 0.9
	_iron_mat = StandardMaterial3D.new()
	_iron_mat.albedo_color = Color(0.13, 0.14, 0.15)
	_iron_mat.roughness = 0.5
	_iron_mat.metallic = 0.35
	var awn_red := StandardMaterial3D.new()
	awn_red.albedo_color = Color(0.45, 0.12, 0.12)
	awn_red.roughness = 0.85
	var awn_green := StandardMaterial3D.new()
	awn_green.albedo_color = Color(0.13, 0.26, 0.17)
	awn_green.roughness = 0.85
	_awning_mats = [awn_red, awn_green]

func _load_texture(nm: String) -> Texture2D:
	var p := "res://assets/textures/%s.png" % nm
	if not ResourceLoader.exists(p):
		push_warning("贴图缺失(回退纯色, street_check 会报红): " + p)
		return null
	return load(p) as Texture2D

## P3 批次4: 挂贴图族 albedo/normal/rough + 世界三平面平铺(跨街道对缝)。
## 贴图缺失→保留纯色不崩,由 street_check 断言负责显性报红(诚实降级)。
func _apply_texture_family(m: StandardMaterial3D, fam: String, tile_m: float, tint: Color, rough: float) -> void:
	m.albedo_color = tint
	m.roughness = rough
	var albedo := _load_texture(fam + "_albedo")
	if albedo == null:
		return
	m.albedo_texture = albedo
	var nrm := _load_texture(fam + "_normal")
	if nrm != null:
		m.normal_enabled = true
		m.normal_texture = nrm
	var rgh := _load_texture(fam + "_rough")
	if rgh != null:
		m.roughness_texture = rgh
	# 三平面世界空间: scale=每米重复数 = 1/tile_m (石块 2m/石板 1.6m/花岗岩 1m 一循环)
	m.uv1_triplanar = true
	m.uv1_world_triplanar = true
	m.uv1_scale = Vector3(1.0 / tile_m, 1.0 / tile_m, 1.0 / tile_m)

## P3 批次6: 按建筑实际宽/高设 wall_width_m/wall_height_m (修复: 首版漏设,
## 窗洞密度全按默认 10×18 算), 并挂墙身拉毛贴图; 尺寸进缓存键 → 每栋窗格与实际对齐。
func _get_facade_material(levels: int, wpf: int, shop: bool, along_w: float, height: float) -> ShaderMaterial:
	var key := "%d_%d_%d_%d_%d" % [levels, wpf, int(shop), int(along_w * 10.0), int(height * 10.0)]
	if _facade_mats.has(key):
		return _facade_mats[key]
	var m = ShaderMaterial.new()
	m.shader = _facade_shader
	m.set_shader_parameter("levels", levels)
	m.set_shader_parameter("windows_per_floor", wpf)
	m.set_shader_parameter("ground_shop", shop)
	m.set_shader_parameter("wall_width_m", along_w)
	m.set_shader_parameter("wall_height_m", height)
	m.set_shader_parameter("wall_tile_m", 1.6)
	if _facade_albedo != null:
		m.set_shader_parameter("wall_tex", _facade_albedo)
		if _facade_normal != null:
			m.set_shader_parameter("wall_nrm", _facade_normal)
		m.set_shader_parameter("wall_tex_on", true)
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
	# P3 批次6: 直接用调色板材质 (旧版新建材质只抄 albedo_color → 丢贴图, 街平面成纯色)
	var wall_mi := MeshInstance3D.new()
	wall_mi.name = "Wall"
	var wbox := BoxMesh.new()
	wbox.size = Vector3(depth, height, along_w)
	wall_mi.mesh = wbox
	var wmat := _wall_mats[int(seed_f * float(_wall_mats.size())) % _wall_mats.size()] as StandardMaterial3D
	wall_mi.material_override = wmat
	wall_mi.position = Vector3(side * depth / 2.0, height / 2.0, 0)
	body.add_child(wall_mi)

	# 屋顶锌灰(前表面起, 略探出)
	var roof_mi := MeshInstance3D.new()
	roof_mi.name = "Roof"
	var rbox := BoxMesh.new()
	rbox.size = Vector3(depth + 0.4, 0.6, along_w + 0.5)
	roof_mi.mesh = rbox
	roof_mi.material_override = _roof_mat
	roof_mi.position = Vector3(side * (depth / 2.0 + 0.05), height, 0)
	body.add_child(roof_mi)

	# 临街立面(窗户 shader 薄盒, 位于前表面 x≈0 稍向街)
	var n_wpf = max(1, int(round(along_w / 2.8)))
	var facade_mi := MeshInstance3D.new()
	facade_mi.name = "Facade"
	var fbox := BoxMesh.new()
	fbox.size = Vector3(0.12, height, along_w)
	facade_mi.mesh = fbox
	facade_mi.material_override = _get_facade_material(levels, n_wpf, true, along_w, height)
	# 薄盒中心: 前表面(side*backoff处,x=0)向街外探 0.06
	facade_mi.position = Vector3(-side * 0.09, height / 2.0, 0)
	body.add_child(facade_mi)

	# P3 批次6: 立面成套细节 (檐口/门/落管/烟囱 + 阳台或老虎窗 + 雨棚)
	_build_facade_details(body, side, along_w, depth, height, levels, seed_f)

	# 碰撞(整墙身)
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(depth, height, along_w)
	col.shape = shape
	col.position = Vector3(side * depth / 2.0, height / 2.0, 0)
	body.add_child(col)

	buildings_root.add_child(body)

## ---------- P3 批次6: 立面成套细节 ----------
## 每栋必有: 檐口(双带) + 入户门(扇+过梁) + 落水管 + 烟囱(身+压顶);
## 按 seed 变体: 阳台(seed≤0.35) XOR 老虎窗(>0.35), 雨棚店铺模块(seed>0.4)。
## 面数纪律(决策29 单栋≤3k / 单街≤25k): 细节满配 152 面/栋,
## worst-case 单街推演 17,576-1,836+51×152=23,492 < 25k; 实测以 street_check 为准。

func _dmesh(parent: Node3D, mesh: Mesh, mat: Material, pos: Vector3, nm: String) -> void:
	var mi := _add_mesh(parent, mesh, mat, pos)
	mi.name = nm

func _build_facade_details(body: StaticBody3D, side: float, along_w: float, depth: float, height: float, levels: int, seed_f: float) -> void:
	var fr2: float = seed_f * 7.3
	fr2 = fr2 - floor(fr2)
	var fr3: float = seed_f * 11.7
	fr3 = fr3 - floor(fr3)
	var floor_h: float = (height - 4.2) / float(max(1, levels))

	# 檐口: 双层石线脚 (顶带探街至 -side*0.40, 滴水带更宽更靠下)
	_dmesh(body, _box_mesh(0.42, 0.20, along_w + 0.36), _trim_mat, Vector3(-side * 0.19, height - 0.16, 0), "Detail_Cornice")
	_dmesh(body, _box_mesh(0.30, 0.14, along_w + 0.52), _trim_mat, Vector3(-side * 0.15, height - 0.35, 0), "Detail_Cornice2")
	# 入户门: 木门扇(朝街外探 5cm 消 z-fight) + 石过梁, 两端交替
	var door_z: float = clampf((1.0 if seed_f < 0.5 else -1.0) * (along_w * 0.5 - 0.85), -1.0 * (along_w * 0.5 - 0.7), along_w * 0.5 - 0.7)
	_dmesh(body, _box_mesh(0.07, 2.15, 1.05), _door_mat, Vector3(-side * 0.165, 1.075, door_z), "Detail_Door")
	_dmesh(body, _box_mesh(0.16, 0.30, 1.35), _trim_mat, Vector3(-side * 0.17, 2.40, door_z), "Detail_DoorTrim")
	# 落水管: 镀锌方管 (BoxMesh 12 面)。首版 CylinderMesh radial5 实测 50 面/根
	# (Godot 圆柱细分远超预期) → 方管既省 38 面/根, 也是巴黎常见锌质做法
	var spout_z: float = (1.0 if fr2 < 0.5 else -1.0) * (along_w * 0.5 - 0.14)
	_dmesh(body, _box_mesh(0.10, height - 0.3, 0.10), _pipe_mat, Vector3(-side * 0.17, (height - 0.3) / 2.0, spout_z), "Detail_Spout")
	# 烟囱: 屋面后部砖体 + 石压顶
	var chim_z: float = (fr3 - 0.5) * along_w * 0.6
	_dmesh(body, _box_mesh(0.8, 1.3, 0.9), _chimney_mat, Vector3(side * depth * 0.7, height + 0.95, chim_z), "Detail_Chimney")
	_dmesh(body, _box_mesh(0.9, 0.12, 1.0), _trim_mat, Vector3(side * depth * 0.7, height + 1.66, chim_z), "Detail_ChimneyCap")
	# 变体: 阳台 (seed≤0.35, 平台+顶杆+3栏杆, 与 shader 阳台铁艺带同层对齐)
	#       或 老虎窗 (>0.35, 窗体+压顶) — 每栋必有其一
	var variant_z: float = (fr2 - 0.5) * along_w * 0.45
	if seed_f <= 0.35:
		var yb: float = 4.2 + floor_h
		_dmesh(body, _box_mesh(1.7, 0.09, 0.6), _trim_mat, Vector3(-side * 0.45, yb - 0.045, variant_z), "Detail_Balcony")
		_dmesh(body, _box_mesh(1.7, 0.05, 0.05), _iron_mat, Vector3(-side * 0.725, yb + 0.52, variant_z), "Detail_BalconyRail")
		for k in 3:
			_dmesh(body, _box_mesh(0.04, 0.5, 0.04), _iron_mat, Vector3(-side * 0.725, yb + 0.27, variant_z + (float(k) - 1.0) * 0.62), "Detail_BalconyBar%d" % k)
	else:
		var dy := height + 0.3   # 屋面顶 (roof 盒顶 = height+0.3)
		_dmesh(body, _box_mesh(0.95, 0.95, 1.05), _trim_mat, Vector3(side * 0.55, dy + 0.475, variant_z), "Detail_Dormer")
		_dmesh(body, _box_mesh(1.15, 0.12, 1.25), _iron_mat, Vector3(side * 0.55, dy + 1.01, variant_z), "Detail_DormerRoof")
	# 店铺模块: 实体雨棚+垂边 (shader 已画店面橱窗/雨棚阴影带, 这里补立体件)
	if seed_f > 0.4:
		var awn := _awning_mats[int(seed_f * 2.0) % _awning_mats.size()] as StandardMaterial3D
		_dmesh(body, _box_mesh(2.3, 0.07, 0.62), awn, Vector3(-side * 0.46, 3.62, 0), "Detail_Awning")
		_dmesh(body, _box_mesh(2.3, 0.16, 0.05), awn, Vector3(-side * 0.745, 3.50, 0), "Detail_AwningValance")

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

## ---------- 地标层 (方案 §P2-B 行4: 五件套首对象, 决策 24/28) ----------
## layout.meta.landmarks[] → GLB 落位 + 碰撞 (layer 1); 面数计入 buildings_root
## 统计; sha 三处绑定由 tools/landmark_tasks.py validate 核 (verify glb_check 步)。
func _build_landmarks():
	var lm_raw = layout.get("meta", {}).get("landmarks", [])
	var lms: Array = lm_raw if lm_raw is Array else []
	for lm in lms:
		if not (lm is Dictionary):
			continue
		var id := String(lm.get("id", ""))
		var res_path := "res://" + String(lm.get("glb", "")).trim_prefix("godot-project/")
		var side := 1.0 if float(lm.get("side", 1)) >= 0.0 else -1.0
		var face := float(lm.get("face", 6.0))
		var s_center := float(lm.get("s_center", 0.0))
		var scene: PackedScene = load(res_path)
		if scene == null:
			push_error("[StreetGenerator] 地标 GLB 加载失败: ", res_path)
			continue
		var node := StaticBody3D.new()
		node.name = "Landmark_" + id
		node.collision_layer = 1
		node.collision_mask = 1
		node.position = Vector3(side * face, 0.0, s_center)
		node.set_meta("source_glb", res_path)
		var inst: Node = scene.instantiate()
		inst.name = "Model"
		node.add_child(inst)
		# 碰撞: 主体含两翼 (x∈[-1.3,0.15], z∈[-11.55,10.95]) + 右端回墙
		var col := CollisionShape3D.new()
		var sh := BoxShape3D.new()
		sh.size = Vector3(1.45, 8.72, 22.5)
		col.shape = sh
		col.position = Vector3(-0.575, 4.36, -0.3)
		node.add_child(col)
		var col2 := CollisionShape3D.new()
		var sh2 := BoxShape3D.new()
		sh2.size = Vector3(5.2, 8.72, 0.6)
		col2.shape = sh2
		col2.position = Vector3(-2.6, 4.36, 11.25)
		node.add_child(col2)
		buildings_root.add_child(node)
		print("[StreetGenerator] 地标 ", id, ": pos=", node.position, " glb=", res_path)

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
