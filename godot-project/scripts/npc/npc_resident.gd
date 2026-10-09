extends "res://scripts/npc/npc_base.gd"

## 居民 NPC（决策 22：Place des Vosges 第二街区 +2，NPC 总量 3 → 5）
## 站定闲望型：不走动（斜街移动适配留待需要时），可正常对话；
## 行走摆动由 pedestrian 演示，居民展示 IDLE 呼吸/闲望/对话动作链。

@export var idle_yaw_amp: float = 0.38    # 闲望左右转头幅度（弧度，±22°）
@export var idle_yaw_speed: float = 0.45  # 转头角速度

var _t: float = 0.0
var _base_yaw: float = 0.0

func _ready():
	super._ready()
	current_state = State.IDLE
	_base_yaw = rotation.y

func _idle_behavior():
	_t += get_physics_process_delta_time()
	# 缓缓左右张望（对话面向玩家时 _animate 的面向逻辑优先，结束后回到闲望）
	var target := _base_yaw + sin(_t * idle_yaw_speed) * idle_yaw_amp
	rotation.y = lerp_angle(rotation.y, target, 0.05)
