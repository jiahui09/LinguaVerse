extends RefCounted

## 街景子系统 — 建筑铭牌 + Label3D 文字 basis 分级 (P2-A 新增)
##
## 证据分级纪律 (资产纪律第 3 条): 每块文字挂 meta:
##   basis = "reported"   文字来自源数据 — OSM name tag → layout buildings[].name
##                        (源: data/osm/rosiers_full.json, 许可 ODbL)
##   basis = "ai-drafted" AI 拟写 / 非源数据文字
##   无 name (null/缺失)  不生成文字 — 来源未知一律不显示
## 当前布局仅 Hôtel Brulart 两段相邻楼段带 OSM 名 → 相邻同名合并 1 块铭牌;
## 其余 23 栋无名楼不挂牌 (null 不显示, 由 street_check 断言覆盖)。
## 牌面 y=3.2 (首层门楣上方), 只贴墙不设碰撞 (高于玩家头部)。

const PARAMS := {
	"face_offset": 0.06,     # 牌心自立面前伸 (朝街), 防 z-fight
	"y": 3.2,                # 牌中心高
	"plaque_w": 1.0,         # 沿街向 (z)
	"plaque_h": 0.44,        # 竖直 (y)
	"plaque_d": 0.06,        # 垂直墙面 (x)
	"label_size": 36,
	"label_pixel": 0.003,    # 字高 ≈0.108m; "Hôtel Brulart" 13 字符 ≈0.84m < 1.0m 牌宽
	"label_outline": 6,
	"label_out_x": 0.05,     # 文字自牌面再前探
	"merge_gap": 0.01,       # 相邻判定: 上一段 s1 ≈ 本段 s0
}

func params() -> Dictionary:
	return PARAMS

func param_hash() -> String:
	return str(PARAMS).sha256_text()

## 相邻同名同侧楼段合并 → runs: [{name, side, s0, s1}]
## (布局序列相邻才合并 — 当前 OSM 段序即里程序; 一个实体一牌, 不重复挂)
static func name_runs(layout: Dictionary, p: Dictionary) -> Array:
	var runs: Array = []
	for b in layout.get("buildings", []):
		var nm = b.get("name", "")
		if typeof(nm) != TYPE_STRING or (nm as String).strip_edges() == "":
			continue  # 无名 / 未知 → 不显示
		var side := 1.0 if float(b["side"]) >= 0.0 else -1.0
		var s0 := float(b["s0"])
		var s1 := float(b["s1"])
		if runs.size() > 0:
			var last: Dictionary = runs[runs.size() - 1]
			if last["name"] == nm and float(last["side"]) == side \
					and absf(float(last["s1"]) - s0) < float(p["merge_gap"]):
				last["s1"] = s1
				continue
		runs.append({"name": nm, "side": side, "s0": s0, "s1": s1})
	return runs

## 装配器调用: 生成 BuildingSigns 容器 (gen = street_generator)
func build(gen) -> Node3D:
	if gen.buildings_root == null:
		return null
	if gen.buildings_root.get_node_or_null("BuildingSigns") != null:
		return gen.buildings_root.get_node_or_null("BuildingSigns")  # 幂等
	var container := Node3D.new()
	container.name = "BuildingSigns"
	var runs := name_runs(gen.layout, PARAMS)
	for i in runs.size():
		_spawn_sign(gen, container, runs[i] as Dictionary, i)
	if runs.size() > 0:
		print("[BuildingSigns] 铭牌 ", runs.size(), " 块 (无名楼 null 不显示)")
	gen.buildings_root.add_child(container)
	return container

func _spawn_sign(gen, parent: Node3D, r: Dictionary, idx: int) -> void:
	var side := float(r["side"])
	var backoff = float(gen.layout["street"].get("backoff", 6.0))
	var s_mid := (float(r["s0"]) + float(r["s1"])) / 2.0

	var sign := Node3D.new()
	sign.name = "Sign_%d" % idx
	# 前立面中心 = side*backoff; 牌向街前探 face_offset → |x| < backoff (不越界)
	sign.position = Vector3(
		side * (backoff - float(PARAMS["face_offset"])),
		float(PARAMS["y"]),
		s_mid)
	sign.set_meta("basis", "reported")
	sign.set_meta("text_name", r["name"])

	# 牌面 (贴墙, 法向沿 x)
	var plaque := MeshInstance3D.new()
	var pbox := BoxMesh.new()
	pbox.size = Vector3(
		float(PARAMS["plaque_d"]),
		float(PARAMS["plaque_h"]),
		float(PARAMS["plaque_w"]))
	plaque.mesh = pbox
	var pm := StandardMaterial3D.new()
	pm.albedo_color = Color(0.90, 0.87, 0.79)  # 浅石色牌面
	pm.roughness = 0.85
	plaque.material_override = pm
	sign.add_child(plaque)

	# 文字: 本地 +Z 为正面 → 绕 Y 转 -90*side 面向街心 (side=-1 → +90 → +X)
	var label := Label3D.new()
	label.text = String(r["name"])
	label.font_size = int(PARAMS["label_size"])
	label.outline_size = int(PARAMS["label_outline"])
	label.pixel_size = float(PARAMS["label_pixel"])
	label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	label.modulate = Color(0.13, 0.11, 0.09)          # 深墨字
	label.outline_modulate = Color(0.95, 0.93, 0.88)   # 浅描边
	label.rotation_degrees = Vector3(0, -90.0 * side, 0)
	label.position = Vector3(-side * float(PARAMS["label_out_x"]), 0.0, 0.0)
	label.set_meta("basis", "reported")        # OSM name tag
	label.set_meta("text_source", "osm_name")  # data/osm/rosiers_full.json
	sign.add_child(label)

	parent.add_child(sign)
