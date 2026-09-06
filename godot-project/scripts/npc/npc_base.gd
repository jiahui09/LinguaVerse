extends CharacterBody3D

## NPC 基类
## 所有 NPC 继承此脚本

@export var npc_name: String = "NPC"
@export var npc_job: String = ""
@export var npc_personality: String = ""
@export var speaks_french: bool = true

enum State { IDLE, WALK, INTERACT, TALKING }
var current_state: State = State.IDLE

# 对话相关
var is_in_conversation: bool = false
var conversation_history: Array = []

signal dialog_started(npc_name: String)
signal dialog_ended(npc_name: String)

func _ready():
	# 设置 NPC 名称标签
	add_to_group("npc")
	$NameLabel.text = npc_name

func _physics_process(_delta: float):
	match current_state:
		State.IDLE:
			_idle_behavior()
		State.WALK:
			_walk_behavior()
		State.INTERACT:
			_interact_behavior()
		State.TALKING:
			_talking_behavior()

## 虚函数：子类重写
func _idle_behavior():
	pass

func _walk_behavior():
	pass

func _interact_behavior():
	pass

func _talking_behavior():
	pass

## 开始对话
func start_dialog():
	is_in_conversation = true
	current_state = State.TALKING
	dialog_started.emit(npc_name)

## 结束对话
func end_dialog():
	is_in_conversation = false
	current_state = State.IDLE
	dialog_ended.emit(npc_name)

## 获取 NPC 信息（用于 Prompt 组装）
func get_npc_info() -> Dictionary:
	return {
		"name": npc_name,
		"job": npc_job,
		"personality": npc_personality,
		"speaks_french": speaks_french,
		"position": global_position,
	}
