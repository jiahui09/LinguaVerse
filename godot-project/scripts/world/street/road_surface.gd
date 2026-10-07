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

func _road(gen, min_s: float, max_s: float) -> void:
	var width = float(gen.layout["street"].get("width", 9.0))
	var thick := float(PARAMS["road_thickness"])
	var col_h := float(PARAMS["road_collision_h"])
	var road := StaticBody3D.new()
	road.name = "Road"
	road.collision_layer = 1
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(width, thick, max_s - min_s)
	mi.mesh = box
	mi.material_override = gen._road_mat
	mi.position = Vector3(0, -thick / 2.0, (min_s + max_s) / 2.0)
	road.add_child(mi)
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(width, col_h, max_s - min_s)
	col.shape = shape
	col.position = Vector3(0, -col_h / 2.0, (min_s + max_s) / 2.0)
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
		mi.position = Vector3(cx, -thick / 2.0, (min_s + max_s) / 2.0)
		sw.add_child(mi)
		var col := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = Vector3(sw_w, col_h, max_s - min_s)
		col.shape = shape
		col.position = Vector3(cx, -col_h / 2.0, (min_s + max_s) / 2.0)
		sw.add_child(col)
		gen.add_child(sw)
