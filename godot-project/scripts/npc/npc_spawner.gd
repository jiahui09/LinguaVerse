extends Node

## NPC 部署器 — 根据街景生成器的布局放置 NPC
## 挂在 Main 下, 等 StreetGenerator 就绪后摆放 5 个 NPC（决策 22: 3 → 5）:
##   - Marie(服务员): 咖啡馆吧台后 (get_cafe_staff_pos)
##   - Pierre(行人): 对面人行道来回走动
##   - Jean(老人): 咖啡馆门旁露台座位
##   - Colette/Antoine(居民): Place des Vosges 第二街区，密度对齐现街（决策 22）

@export var waiter_scene: PackedScene
@export var pedestrian_scene: PackedScene
@export var elder_scene: PackedScene
@export var resident_scene: PackedScene

var spawned: Array = []

func _ready():
	# 等 StreetGenerator 完成构建
	await get_tree().process_frame
	await get_tree().process_frame
	spawn_all()

func spawn_all():
	var gen := get_tree().get_first_node_in_group("street_generator")
	if gen == null:
		push_warning("[NPCSpawner] 找不到 StreetGenerator")
		return

	# --- Marie: 吧台后 (面向门口/街道) ---
	if waiter_scene:
		var marie := waiter_scene.instantiate() as Node3D
		var staff_pos: Vector3 = gen.get_cafe_staff_pos()
		marie.position = staff_pos
		# 咖啡馆门面朝 -X(街)：Marie 必须也朝 -X 才是"面向顾客"。
		# Node3D 前向 = -Z，绕 Y 转 θ 后前向 = (-sinθ, 0, -cosθ)：
		#   θ=-90° → +X（吧台后侧/后墙，错）；θ=+90° → -X（街道/门口，对）
		# 旧值 -90 会让 Marie 背对顾客盯着后墙，故修正为 +90。
		marie.rotation_degrees = Vector3(0, 90, 0)
		add_child(marie)
		spawned.append(marie)
		print("[NPCSpawner] Marie 吧台后: ", staff_pos)

	# --- Jean: 咖啡馆门前 sidewalk (同侧 +X, 门前侧位) ---
	if elder_scene:
		var jean := elder_scene.instantiate() as Node3D
		var door_pos: Vector3 = gen.get_cafe_door_pos()
		# 门前人行道侧位: x=人行道中(≈5.5), z=咖啡馆门前侧(z≈0 端)
		jean.position = Vector3(5.5, 0, door_pos.z - 8.0)
		jean.rotation_degrees = Vector3(0, 180, 0)
		add_child(jean)
		spawned.append(jean)

	# --- Pierre: 对面人行道 (side=-1 → x 负侧) ---
	if pedestrian_scene:
		var pierre := pedestrian_scene.instantiate() as Node3D
		pierre.set("walk_x", -5.2)
		pierre.position = Vector3(-5.2, 0, -6)
		add_child(pierre)
		spawned.append(pierre)

	# --- Colette / Antoine: Place des Vosges 居民（决策 22 第二街区 +2 → 总量 5）---
	var vg: Node3D = get_tree().root.find_child("StreetGeneratorVosges", true, false)
	if resident_scene and vg != null:
		var folks := [
			{"name": "Colette", "job_fr": "Voisine", "glb": "npc_colette",
			 "local": Vector3(-5.2, 0, 206.0), "yaw": -90.0,   # 拱廊前, 面街心(+X)
			 "personality": "热情的街坊，喜欢聊广场上的老房子，说话带点怀旧"},
			{"name": "Antoine", "job_fr": "Voisin", "glb": "npc_antoine",
			 "local": Vector3(5.2, 0, 252.0), "yaw": 90.0,    # 对侧, 面街心(-X)
			 "personality": "安静的退休老人，说话慢条斯理，记得街上每栋楼的来历"},
		]
		for f in folks:
			var r := resident_scene.instantiate() as Node3D
			r.set("npc_name", f["name"])
			r.set("npc_job", "邻居")
			r.set("npc_job_fr", f["job_fr"])
			r.set("npc_personality", f["personality"])
			# 进树前挂上模型（_ready 的 _resolve_visuals 才找得到 Model）
			var model: PackedScene = load("res://assets/models/%s.glb" % f["glb"])
			if model:
				var m := model.instantiate()
				m.name = "Model"
				r.add_child(m)
			# 先设好 vg 局部坐标再 add（add 瞬间 _ready 跑，语义已是 vg 局部）
			r.position = f["local"]
			r.rotation_degrees = Vector3(0, f["yaw"], 0)
			# 同 parent 下重名会被 Godot 匿名化（@Type@id）→ 手动唯一命名
			r.name = "NPCResident_" + str(f["name"])
			vg.add_child(r)
			spawned.append(r)
			print("[NPCSpawner] %s Vosges 居民 局部 %v → 世界 %v"
				% [f["name"], f["local"], r.global_position])
	else:
		if resident_scene == null:
			push_warning("[NPCSpawner] resident_scene 未配置")
		if vg == null:
			push_warning("[NPCSpawner] 找不到 StreetGeneratorVosges")
