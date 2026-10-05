extends Node

## NPC 部署器 — 根据街景生成器的布局放置 NPC
## 挂在 Main 下, 等 StreetGenerator 就绪后摆放 3 个 NPC:
##   - Marie(服务员): 咖啡馆吧台后 (get_cafe_staff_pos)
##   - Pierre(行人): 对面人行道来回走动
##   - Jean(老人): 咖啡馆门旁露台座位

@export var waiter_scene: PackedScene
@export var pedestrian_scene: PackedScene
@export var elder_scene: PackedScene

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
