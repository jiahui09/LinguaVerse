extends "res://scripts/npc/npc_base.gd"

## 服务员 NPC — 咖啡馆柜台后
## V1 第一个可对话的 NPC

@export var walk_path: NodePath  # 可选：巡逻路径

var _idle_timer: float = 0.0
var _idle_action_interval: float = 3.0

func _ready():
	npc_name = "Marie"
	npc_job = "咖啡馆服务员"
	npc_personality = "热情、忙碌，偶尔不耐烦"
	speaks_french = true
	super._ready()

func _idle_behavior():
	_idle_timer += get_process_delta_time()
	if _idle_timer >= _idle_action_interval:
		_idle_timer = 0.0
		# 随机轻微动作：看柜台、整理东西（视觉上只是状态切换）
		# V1 不做动画，保持静止即可

func _talking_behavior():
	# 对话中面向玩家（简单旋转）
	pass
