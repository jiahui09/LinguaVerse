extends "res://scripts/npc/npc_base.gd"

## 服务员 NPC — 咖啡馆柜台后
## V1 第一个可对话的 NPC
##
## 额外职责：点单世界反馈（P1-4）——玩家输入含点单关键词且收到回复后，
## 吧台上多一杯咖啡（最多同时 3 杯，超出回收最早的一杯），并放一声杯碟轻碰。

const CUP_AUDIO := "res://assets/audio/sfx/cup_clink.wav"
const MAX_CUPS := 3

@export var walk_path: NodePath  # 可选：巡逻路径

var _idle_timer: float = 0.0
var _idle_action_interval: float = 3.0
var _cups: Array = []
var _clink_player: AudioStreamPlayer3D

func _ready():
	npc_name = "Marie"
	npc_job = "咖啡馆服务员"
	npc_job_fr = "Serveuse de café"   # 名牌副标题（纯氛围信息）
	npc_personality = "热情、忙碌，偶尔不耐烦"
	speaks_french = true
	super._ready()
	current_state = State.IDLE

func _idle_behavior():
	_idle_timer += get_process_delta_time()
	if _idle_timer >= _idle_action_interval:
		_idle_timer = 0.0
		# 随机轻微动作：看柜台、整理东西（视觉上只是状态切换）
		# V1 无骨骼动画，呼吸/眨眼/思考动作/点头由 npc_base 统一驱动

func _talking_behavior():
	# 对话中面向玩家由 npc_base._animate 统一处理
	pass

## ---------- 点单世界反馈（P1-4） ----------

## 由 DialogManager 在"点单 → 收到回复"之后调用
func serve_order():
	var slot := _cups.size()
	if slot >= MAX_CUPS:
		var oldest: Node = _cups.pop_front()
		if oldest and is_instance_valid(oldest):
			oldest.queue_free()
		slot = _cups.size()
	var cup := _build_cup(slot)
	add_child(cup)
	_cups.append(cup)
	_play_clink()

func get_served_count() -> int:
	return _cups.size()

## 吧台上的一杯咖啡（纯视觉；吧台本身已有碰撞，玩家翻不过去）
## 坐标系推导（Marie 与咖啡馆朝向不同，只差旋转+平移，故按世界坐标反算）：
##   咖啡馆 root = (6.0, 0, 4.34)，yaw -90°，吧台 café 局部 x∈[-1.8,1.8]、
##   z∈[-6.2,-5.6]、顶 y=1.3 → 世界 x∈[11.6,12.2]、z∈[2.54,6.14]、y=1.3。
##   Marie 世界 (12.3, 0, 4.34)、yaw +90°（面向 -X 街道）。
##   世界 → Marie 局部：x_local = -(z_w - 4.34)、z_local = x_w - 12.3。
##   取杯位世界 x=11.8（台面中前）、z = 4.34 + {+0.7, 0, -0.7}
##   → Marie 局部 base = (0.7 - 0.7*i, 1.3, -0.5)。
func _build_cup(index: int) -> Node3D:
	var cup := Node3D.new()
	cup.name = "Cup%d" % (index + 1)
	var base := Vector3(0.7 - 0.7 * float(index), 1.3, -0.5)   # 吧台台面上

	var ceramic := StandardMaterial3D.new()
	ceramic.albedo_color = Color(0.95, 0.94, 0.92)
	ceramic.roughness = 0.3

	# 杯碟
	var saucer := MeshInstance3D.new()
	var saucer_mesh := CylinderMesh.new()
	saucer_mesh.top_radius = 0.062
	saucer_mesh.bottom_radius = 0.056
	saucer_mesh.height = 0.012
	saucer_mesh.radial_segments = 16
	saucer.mesh = saucer_mesh
	saucer.material_override = ceramic
	saucer.position = base + Vector3(0, 0.006, 0)
	cup.add_child(saucer)

	# 杯身
	var body := MeshInstance3D.new()
	var body_mesh := CylinderMesh.new()
	body_mesh.top_radius = 0.036
	body_mesh.bottom_radius = 0.03
	body_mesh.height = 0.072
	body_mesh.radial_segments = 16
	body.mesh = body_mesh
	body.material_override = ceramic
	body.position = base + Vector3(0, 0.012 + 0.036, 0)
	cup.add_child(body)

	# 咖啡液面
	var coffee := MeshInstance3D.new()
	var coffee_mesh := CylinderMesh.new()
	coffee_mesh.top_radius = 0.032
	coffee_mesh.bottom_radius = 0.032
	coffee_mesh.height = 0.006
	coffee_mesh.radial_segments = 16
	coffee.mesh = coffee_mesh
	var coffee_mat := StandardMaterial3D.new()
	coffee_mat.albedo_color = Color(0.28, 0.17, 0.1)
	coffee_mat.roughness = 0.4
	coffee.material_override = coffee_mat
	coffee.position = base + Vector3(0, 0.012 + 0.072 - 0.005, 0)
	cup.add_child(coffee)

	return cup

## 杯碟轻碰音效；素材缺失/未导入时静默降级（不报错、不中断对话）
func _play_clink():
	if _clink_player == null:
		if not ResourceLoader.exists(CUP_AUDIO):
			return
		_clink_player = AudioStreamPlayer3D.new()
		_clink_player.name = "ClinkPlayer"
		_clink_player.stream = load(CUP_AUDIO)
		_clink_player.unit_size = 6.0
		_clink_player.volume_db = -4.0
		add_child(_clink_player)
	if _clink_player.stream:
		_clink_player.play()
