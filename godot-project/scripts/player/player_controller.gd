extends CharacterBody3D

## 第一人称玩家控制器
## WASD 移动 + 鼠标视角 + 交互触发

@export var move_speed: float = 5.0
@export var mouse_sensitivity: float = 0.002
@export var gravity: float = 9.8

var yaw: float = 0.0
var pitch: float = 0.0
var is_in_dialog: bool = false

@onready var camera: Camera3D = $Camera3D
@onready var interaction_ray: RayCast3D = $Camera3D/InteractionRay

func _ready():
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	# 连接交互信号
	interaction_ray.target_found.connect(_on_target_found)
	interaction_ray.target_lost.connect(_on_target_lost)

func _unhandled_input(event: InputEvent):
	# 对话中不处理移动和视角
	if is_in_dialog:
		return

	# 鼠标视角控制
	if event is InputEventMouseMotion:
		yaw -= event.relative.x * mouse_sensitivity
		pitch -= event.relative.y * mouse_sensitivity
		pitch = clamp(pitch, deg_to_rad(-89), deg_to_rad(89))
		rotation.y = yaw
		camera.rotation.x = pitch

	# ESC 释放/捕获鼠标
	if event.is_action_pressed("ui_cancel"):
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		else:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	# 点击重新捕获鼠标
	if event is InputEventMouseButton and event.pressed:
		if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	# E 键交互
	if event.is_action_pressed("interact") and not is_in_dialog:
		_try_start_dialog()

func _physics_process(delta: float):
	if is_in_dialog:
		return

	# 重力
	if not is_on_floor():
		velocity.y -= gravity * delta

	# 移动方向
	var input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var direction = (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()

	if direction:
		velocity.x = direction.x * move_speed
		velocity.z = direction.z * move_speed
	else:
		velocity.x = move_toward(velocity.x, 0, move_speed)
		velocity.z = move_toward(velocity.z, 0, move_speed)

	move_and_slide()

## 尝试开始对话
func _try_start_dialog():
	var target = interaction_ray.get_target()
	if target == null:
		return

	# 找到对话管理器
	var dialog_manager = get_tree().get_first_node_in_group("dialog_manager")
	if dialog_manager == null:
		# 备用：直接查找
		dialog_manager = get_node_or_null("/root/Main/DialogManager")

	if dialog_manager:
		is_in_dialog = true
		dialog_manager.start_dialog_with(target)

## 由 DialogManager 调用，结束对话
func end_dialog():
	is_in_dialog = false
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

## 交互目标发现
func _on_target_found(npc: Node):
	# V1 不做视觉提示，后续可加准星高亮
	pass

## 交互目标丢失
func _on_target_lost():
	pass
