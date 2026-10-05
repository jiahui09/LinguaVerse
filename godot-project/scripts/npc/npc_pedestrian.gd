extends "res://scripts/npc/npc_base.gd"

## 行人 NPC — 沿人行道走动（平行于街道 z 轴，x 固定在人行道）

@export var walk_speed: float = 1.2
@export var walk_x: float = 5.2       # 人行道 x 位置
@export var min_z: float = -18.0
@export var max_z: float = 18.0

var _walk_forward: bool = true

func _ready():
	npc_name = "Pierre"
	npc_job = "路人"
	npc_job_fr = "Passant"   # 名牌副标题（纯氛围信息）
	npc_personality = "中性，匆忙赶路，不太爱闲聊"
	speaks_french = true
	super._ready()
	current_state = State.WALK
	position.x = walk_x

func _walk_behavior():
	var speed = walk_speed if _walk_forward else -walk_speed
	velocity = Vector3(0, 0, speed)
	rotation.y = PI if _walk_forward else 0.0

	if global_position.z > max_z:
		_walk_forward = false
	elif global_position.z < min_z:
		_walk_forward = true

	# 保持在人行道上
	global_position.x = walk_x
	move_and_slide()
