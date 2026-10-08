extends RefCounted

## 街景子系统 — 路面 / 人行道 (P2-A 自 street_generator.gd 迁入)
##
## 所有权契约: 每子系统一个写入者; 跨界改动经装配器 street_generator.gd 串行接入。
## 坐标: 街道沿 Z (布局 s 里程 → 世界 z), 路面中心 x=0,
##        人行道 |x| ∈ [width/2, backoff]。
## 宽度/后退取自 layout.street → 由 manifest 的 layout sha256 覆盖;
## PARAMS 只含代码常量 (板厚/碰撞高), 经 param_hash 进资产清单。

const PARAMS := {
	"road_thickness": 0.12,          # 路面盒厚 (顶面 y=0)
	"road_collision_h": 0.5,         # 路面碰撞盒高
	"sidewalk_thickness": 0.14,      # 人行道盒厚 (顶面 y=0)
	"sidewalk_collision_h": 0.6,     # 人行道碰撞盒高
}

func params() -> Dictionary:
	return PARAMS

func param_hash() -> String:
	return str(PARAMS).sha256_text()

## 装配器调用: 生成路面 + 两侧人行道 (gen = street_generator 实例)
func build(gen, min_s: float, max_s: float) -> void:
	_road(gen, min_s, max_s)
	_sidewalks(gen, min_s, max_s)
	_decor(gen, min_s, max_s)

## P3 批次4: 路缘石带 + 井盖贴片 (纯装饰, 无碰撞 → 不进 layer 语义;
## 面数 ~每街 +40 三角形, 离 25k 预算可忽略)
func _decor(gen, min_s: float, max_s: float) -> void:
	var width = float(gen.layout["street"].get("width", 9.0))
	var drop = float(gen.layout["street"].get("surface_drop", 0.0))
	var z0: float = min_s + 1.5
	var z1: float = max_s - 1.5
	if z1 - z0 < 4.0:
		return
	var root := Node3D.new()
	root.name = "RoadDecor"
	gen.add_child(root)

	# 路缘石: 双侧花岗岩带 x ∈ [路宽/2-0.01, 路宽/2+0.07],
	# 内面比人行道面外挑 1cm (盖住人行道立脸, 不 z-fighting), 顶面高出 2mm
	for side in [1.0, -1.0]:
		var curb := MeshInstance3D.new()
		curb.name = "Curb" if side > 0.0 else "CurbM"
		var box := BoxMesh.new()
		box.size = Vector3(0.08, 0.152, z1 - z0)
		curb.mesh = box
		curb.material_override = gen._curb_mat
		curb.position = Vector3(side * (width / 2.0 + 0.03), -0.074, (z0 + z1) / 2.0)
		root.add_child(curb)

	# 井盖: 沿路每隔 26m 交替左右 (QuadMesh 贴片, 高出路面 6mm 消 z-fighting)
	var mmat := StandardMaterial3D.new()
	mmat.albedo_color = Color(1, 1, 1)
	mmat.albedo_texture = gen._manhole_albedo
	if gen._manhole_normal != null:
		mmat.normal_enabled = true
		mmat.normal_texture = gen._manhole_normal
	mmat.roughness = 0.62
	mmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var z: float = z0 + 8.0
	var idx := 0
	while z <= z1:
		var mh := MeshInstance3D.new()
		mh.name = "Manhole_%d" % idx
		var quad := QuadMesh.new()
		quad.size = Vector2(0.9, 0.9)
		mh.mesh = quad
		mh.material_override = mmat
		mh.rotation_degrees = Vector3(-90.0, 0.0, 0.0)   # 面法线 +Y 朝上
		mh.position = Vector3(1.7 if idx % 2 == 0 else -1.7, -drop + 0.006, z)
		root.add_child(mh)
		idx += 1
		z += 26.0

func _road(gen, min_s: float, max_s: float) -> void:
	var width = float(gen.layout["street"].get("width", 9.0))
	var thick := float(PARAMS["road_thickness"])
	var col_h := float(PARAMS["road_collision_h"])
	# 批次2: surface_drop — 转角与邻街路面共面相交时整体下沉消 z-fighting
	var drop := float(gen.layout["street"].get("surface_drop", 0.0))
	var road := StaticBody3D.new()
	road.name = "Road"
	road.collision_layer = 1
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(width, thick, max_s - min_s)
	mi.mesh = box
	mi.material_override = gen._road_mat
	mi.position = Vector3(0, -thick / 2.0 - drop, (min_s + max_s) / 2.0)
	road.add_child(mi)
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(width, col_h, max_s - min_s)
	col.shape = shape
	col.position = Vector3(0, -col_h / 2.0 - drop, (min_s + max_s) / 2.0)
	road.add_child(col)
	gen.add_child(road)

func _sidewalks(gen, min_s: float, max_s: float) -> void:
	var width = float(gen.layout["street"].get("width", 9.0))
	var backoff = float(gen.layout["street"].get("backoff", 6.0))
	var sw_w = backoff - width / 2.0
	if sw_w <= 0.0:
		return
	var thick := float(PARAMS["sidewalk_thickness"])
	var col_h := float(PARAMS["sidewalk_collision_h"])
	var drop := float(gen.layout["street"].get("surface_drop", 0.0))
	for side in [1.0, -1.0]:
		var sw := StaticBody3D.new()
		sw.name = "Sidewalk" if side > 0 else "SidewalkM"
		sw.collision_layer = 1
		var cx = side * (width / 2.0 + sw_w / 2.0)
		var mi := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(sw_w, thick, max_s - min_s)
		mi.mesh = box
		mi.material_override = gen._sidewalk_mat
		mi.position = Vector3(cx, -thick / 2.0 - drop, (min_s + max_s) / 2.0)
		sw.add_child(mi)
		var col := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = Vector3(sw_w, col_h, max_s - min_s)
		col.shape = shape
		col.position = Vector3(cx, -col_h / 2.0 - drop, (min_s + max_s) / 2.0)
		sw.add_child(col)
		gen.add_child(sw)
