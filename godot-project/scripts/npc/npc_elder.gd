extends "res://scripts/npc/npc_base.gd"

## 老人 NPC — 坐在街边长椅/咖啡馆露台

@export var look_timer: float = 0.0
@export var look_interval: float = 4.0

func _ready():
	npc_name = "Jean"
	npc_job = "退休老人"
	npc_job_fr = "Retraité"   # 名牌副标题（纯氛围信息）
	npc_personality = "友善、健谈，喜欢讲玛黑区的故事"
	speaks_french = true
	super._ready()
	current_state = State.IDLE

func _idle_behavior():
	look_timer += get_process_delta_time()
	if look_timer >= look_interval:
		look_timer = 0.0
		# 偶尔转向街道方向（简单旋转）
		rotation.y = -PI / 4.0 + randf_range(-0.3, 0.3)
