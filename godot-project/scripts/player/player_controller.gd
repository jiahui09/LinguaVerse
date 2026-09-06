extends CharacterBody3D

## 第一人称玩家控制器
## WASD 移动 + 鼠标视角控制

@export var move_speed: float = 5.0
@export var mouse_sensitivity: float = 0.002
@export var gravity: float = 9.8
@export var jump_velocity: float = 4.5

var yaw: float = 0.0
var pitch: float = 0.0

@onready var camera: Camera3D = $Camera3D

func _ready():
	# 捕获鼠标
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _unhandled_input(event: InputEvent):
	# 鼠标视角控制
	if event is InputEventMouseMotion:
		yaw -= event.relative.x * mouse_sensitivity
		pitch -= event.relative.y * mouse_sensitivity
		pitch = clamp(pitch, deg_to_rad(-89), deg_to_rad(89))
		
		rotation.y = yaw
		camera.rotation.x = pitch
	
	# ESC 释放鼠标
	if event.is_action_pressed("ui_cancel"):
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		else:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	
	# 点击重新捕获鼠标
	if event is InputEventMouseButton and event.pressed:
		if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _physics_process(delta: float):
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
