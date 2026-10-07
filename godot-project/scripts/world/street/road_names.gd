extends RefCounted

## 街景子系统 — 路名牌 + 方位词 (P2-A 新增)
## 借 GTA_SZ city-road-names.ts 纪律: "Context labels are game directions, never
## replacements for the OSM name" — 主行永远是源数据街名 (reported),
## 方位词只是游戏上下文 (ai-drafted), 两者都挂 meta 标注证据等级。
##
## 方位词 = 世界坐标系 (+Z=北段 / -Z=南段, 与 game_manager 分区 street_north/
## street_south 同一口径), 不声称真实罗盘方位 (meta.street_axis_deg 未做端点映射)。
##
## 位置: 街道两端、施工围栏线内缩 (读牌时机 = 走进这条街), +X 人行道;
##       端点公式与 street_furniture 围栏同式 (s0−1 / s1+1), street_check 断言对齐。
## 贴牌朝向: 南端牌面向 +Z (街内侧), 北端牌面向 -Z。

const PARAMS := {
	"end_inset": 2.0,        # 自端点内缩, 避开施工围栏本体 (z 深 0.35)
	"x": 4.9,                # +X 人行道 (树/灯带 4.78 外侧; 内侧通道 1.04m > 玩家 0.6)
	"post_r": 0.06,
	"post_h": 2.6,
	"plate_w": 1.6,          # 沿街向 (x 方向展开, 面向 ±Z)
	"plate_h": 0.52,
	"plate_d": 0.06,
	"plate_y": 2.72,         # = (name_y + dir_y) / 2
	"name_y": 2.86,
	"dir_y": 2.58,
	"name_font": 40,         # "Rue des Rosiers" 15 字符 ≈1.08m < 1.6m 牌宽
	"dir_font": 24,
	"pixel_size": 0.003,
	"dir_north": "vers le Nord",   # 世界 +Z 端
	"dir_south": "vers le Sud",    # 世界 -Z 端
}

func params() -> Dictionary:
	return PARAMS

func param_hash() -> String:
	return str(PARAMS).sha256_text()

## 装配器调用: 两端各一座路名牌 (gen = street_generator)
func build(gen, min_s: float, max_s: float) -> Node3D:
	if gen.buildings_root == null:
		return null
	if gen.buildings_root.get_node_or_null("RoadNames") != null:
		return gen.buildings_root.get_node_or_null("RoadNames")  # 幂等
	var container := Node3D.new()
	container.name = "RoadNames"

	# 端点 (与围栏同式, 不硬编码); 夹回路面范围防越界
	var s0_min := 1e9
	var s1_max := -1e9
	for b in gen.layout.get("buildings", []):
		s0_min = min(s0_min, float(b["s0"]))
		s1_max = max(s1_max, float(b["s1"]))
	var inset := float(PARAMS["end_inset"])
	var z_south := clampf(s0_min - 1.0 + inset, min_s + 1.0, max_s - 1.0)
	var z_north := clampf(s1_max + 1.0 - inset, min_s + 1.0, max_s - 1.0)

	_spawn_plate(gen, container, z_south, false)  # 南端 → 面向 +Z
	_spawn_plate(gen, container, z_north, true)   # 北端 → 面向 -Z
	gen.buildings_root.add_child(container)
	return container

func _spawn_plate(gen, parent: Node3D, z: float, north_end: bool) -> void:
	var idx := 1 if north_end else 0
	var x := float(PARAMS["x"])
	# 朝向: 文字贴在面向街内侧的一面 — 南端牌面法向 +Z (rot 0),
	#       北端法向 -Z (rot 180); 两个 Label3D 同面同转, 读向一致。
	var face_sign := -1.0 if north_end else 1.0
	var face_rot := 180.0 if north_end else 0.0

	var plate := Node3D.new()
	plate.name = "RoadPlate_%d" % idx
	plate.position = Vector3(x, 0.0, z)

	# 立柱 (层 4 装饰: 玩家撞, NPC 不撞)
	var post := StaticBody3D.new()
	post.name = "Post"
	post.collision_layer = 4
	post.collision_mask = 0
	var cyl := CylinderMesh.new()
	cyl.top_radius = float(PARAMS["post_r"])
	cyl.bottom_radius = float(PARAMS["post_r"])
	cyl.height = float(PARAMS["post_h"])
	cyl.radial_segments = 8
	var pmat := StandardMaterial3D.new()
	pmat.albedo_color = Color(0.16, 0.20, 0.18)  # 墨绿铁艺
	pmat.roughness = 0.6
	var mi := MeshInstance3D.new()
	mi.mesh = cyl
	mi.material_override = pmat
	mi.position = Vector3(0, float(PARAMS["post_h"]) / 2.0, 0)
	post.add_child(mi)
	var col := CollisionShape3D.new()
	var cshape := CylinderShape3D.new()
	cshape.radius = float(PARAMS["post_r"])
	cshape.height = float(PARAMS["post_h"])
	col.shape = cshape
	col.position = Vector3(0, float(PARAMS["post_h"]) / 2.0, 0)
	post.add_child(col)
	plate.add_child(post)

	# 牌面 (宽沿 x, 厚沿 z)
	var panel := MeshInstance3D.new()
	var pbox := BoxMesh.new()
	pbox.size = Vector3(float(PARAMS["plate_w"]), float(PARAMS["plate_h"]), float(PARAMS["plate_d"]))
	panel.mesh = pbox
	var panel_mat := StandardMaterial3D.new()
	panel_mat.albedo_color = Color(0.93, 0.92, 0.88)  # 白搪瓷
	panel_mat.roughness = 0.5
	panel.material_override = panel_mat
	panel.position = Vector3(0, float(PARAMS["plate_y"]), 0)
	plate.add_child(panel)

	# 主行: OSM 街名 (源数据 → reported)
	var street_name := String(gen.layout.get("street", {}).get("name", ""))
	if street_name != "":
		var name_label := _label(
			street_name, int(PARAMS["name_font"]), Color(0.10, 0.14, 0.35),  # 深蓝字
			Vector3(0, float(PARAMS["name_y"]), face_sign * (float(PARAMS["plate_d"]) / 2.0 + 0.01)),
			face_rot)
		name_label.name = "StreetName"
		name_label.set_meta("basis", "reported")
		name_label.set_meta("text_source", "osm_street_name")
		plate.add_child(name_label)

	# 方位词: 游戏世界上下文 (+Z=北段/−Z=南段, 与 handbook 分区同口径)
	var dir_text := String(PARAMS["dir_north"] if north_end else PARAMS["dir_south"])
	var dir_label := _label(
		dir_text, int(PARAMS["dir_font"]), Color(0.28, 0.30, 0.33),
		Vector3(0, float(PARAMS["dir_y"]), face_sign * (float(PARAMS["plate_d"]) / 2.0 + 0.01)),
		face_rot)
	dir_label.name = "DirHint"
	dir_label.set_meta("basis", "ai-drafted")   # 游戏方位提示, 非源数据
	dir_label.set_meta("text_source", "game_world_frame")
	plate.add_child(dir_label)

	parent.add_child(plate)
	print("[RoadNames] 路名牌 idx=", idx, " z=", z, " \"", street_name, "\" / ", dir_text)

func _label(text: String, font_px: int, color: Color, pos: Vector3, rot_y: float) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.font_size = font_px
	l.outline_size = 4
	l.pixel_size = float(PARAMS["pixel_size"])
	l.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	l.modulate = color
	l.outline_modulate = Color(0.97, 0.97, 0.95)
	l.position = pos
	l.rotation_degrees = Vector3(0, rot_y, 0)
	return l
