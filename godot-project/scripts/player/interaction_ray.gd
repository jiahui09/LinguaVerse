extends RayCast3D

## 交互射线
## 从玩家相机中心向前发射，检测可交互 NPC
## 挂载到 Camera3D 下，跟随视角旋转

@export var interact_distance: float = 3.0

signal target_found(npc: Node)
signal target_lost()

var current_target: Node = null

func _ready():
	target_position = Vector3(0, 0, -interact_distance)
	enabled = true
	# 只检测 NPC 层（层 2）
	collision_mask = 2

func _physics_process(_delta: float):
	if is_colliding():
		var collider = get_collider()
		# 向上查找有 npc_base 脚本的父节点
		var npc = _find_npc_parent(collider)
		if npc and npc != current_target:
			current_target = npc
			target_found.emit(npc)
	elif current_target:
		current_target = null
		target_lost.emit()

## 从碰撞体向上查找 NPC 父节点
func _find_npc_parent(node: Node) -> Node:
	var current = node
	while current:
		if current.has_method("get_npc_info"):
			return current
		current = current.get_parent()
	return null

## 获取当前瞄准的 NPC（供外部查询）
func get_target() -> Node:
	return current_target
