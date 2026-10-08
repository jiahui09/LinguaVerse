extends CharacterBody3D

## 第一人称玩家控制器
## WASD 移动 + 鼠标视角 + 交互触发

@export var move_speed: float = 5.0
@export var accel: float = 35.0        # 起步/转向加速（操作逻辑 §2.2：~0.15s 到速）
@export var decel: float = 30.0        # 停步减速
@export var mouse_sensitivity: float = 0.002
@export var gravity: float = 9.8

var yaw: float = 0.0
var pitch: float = 0.0
var is_in_dialog: bool = false
var ui_blocked: bool = false   # 手册等全屏 UI 打开时冻结移动与视角（操作逻辑 §2.2）

@onready var camera: Camera3D = $Camera3D
@onready var interaction_ray: RayCast3D = $Camera3D/InteractionRay

# ── P3 批次3：微幅头摆 + 同步脚步（docs/操作逻辑 决策26；幅度小到不致眩晕）──
const BOB_STRIDE := 1.4        # 步幅(米)：水平速度/步幅 = 步频(Hz)
const BOB_AMP_Y := 0.028       # 纵向沉浮(米)，恒 ≤0 不顶天花板
const BOB_AMP_X := 0.014       # 横向摇摆(米)
const BOB_RETURN_SPEED := 10.0 # 停步回中速率（帧率无关 lerp 系数 1/s）
var _bob_phase: float = 0.0
var _bob_rest: Vector3 = Vector3.ZERO
var _last_step_index: int = 0
var _step_count: int = 0       # 累计脚步（测试断言钩子）
var _foot_player: AudioStreamPlayer

func _ready():
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	# 连接交互信号
	interaction_ray.target_found.connect(_on_target_found)
	interaction_ray.target_lost.connect(_on_target_lost)
	_bob_rest = camera.position
	_setup_footsteps()
	# 设置接线：灵敏度/FOV 读全局设置并随设置变更更新（此前存了从不读）
	# GameManager 用节点解析（-s headless 模式下自动加载不注册全局标识，沿用代码库约定）
	var gm := get_node_or_null("/root/GameManager")
	if gm:
		_apply_view_settings(gm)
		gm.settings_changed.connect(_on_settings_changed)

func _setup_footsteps() -> void:
	_foot_player = AudioStreamPlayer.new()
	_foot_player.name = "FootstepPlayer"
	_foot_player.bus = "Master"
	_foot_player.volume_db = -4.0
	var stream = load("res://assets/audio/sfx/footstep.wav")
	if stream is AudioStream:
		_foot_player.stream = stream
	add_child(_foot_player)

func _apply_view_settings(gm: Node) -> void:
	mouse_sensitivity = float(gm.get_setting("mouse_sensitivity"))
	camera.fov = float(gm.get_setting("fov"))

func _on_settings_changed(key: String, _value: Variant):
	if key == "mouse_sensitivity" or key == "fov":
		var gm := get_node_or_null("/root/GameManager")
		if gm:
			_apply_view_settings(gm)

func _unhandled_input(event: InputEvent):
	# 手册等全屏 UI 打开：移动/视角/ESC/点击全部让路（手册自己负责关闭与鼠标）
	if ui_blocked:
		return

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

	# ESC 归暂停面板（GameManager）：开合暂停 + 鼠标显隐统一由 toggle_pause 管，
	# 本控制器不再抢 ESC（此前两处同时消费同一事件，鼠标状态互相打架）

	# 点击重新捕获鼠标
	if event is InputEventMouseButton and event.pressed:
		if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	# E 键交互
	if event.is_action_pressed("interact") and not is_in_dialog:
		_try_start_dialog()

func _physics_process(delta: float):
	# 对话中打字时禁止移动（WASD 是法语字母）；失焦后可走开（决策 9）
	var typing := false
	if is_in_dialog:
		var dm = get_tree().get_first_node_in_group("dialog_manager")
		typing = dm != null and dm.has_method("is_player_typing") and dm.is_player_typing()

	# 重力
	if not is_on_floor():
		velocity.y -= gravity * delta

	# 移动方向（手册打开时冻结输入；对话打字中 WASD 为法语字母不移动）
	var input_dir := Vector2.ZERO
	if not typing and not ui_blocked:
		input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var direction = (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()

	# 加减速平滑：起步/转向按 accel 渐速，停步按 decel 渐停（不再瞬时跳变）
	if direction:
		velocity.x = move_toward(velocity.x, direction.x * move_speed, accel * delta)
		velocity.z = move_toward(velocity.z, direction.z * move_speed, accel * delta)
	else:
		velocity.x = move_toward(velocity.x, 0.0, decel * delta)
		velocity.z = move_toward(velocity.z, 0.0, decel * delta)

	move_and_slide()
	_update_bob(delta)

## 微幅头摆 + 同步脚步：走动时相机在基线位做沉浮/摇摆，半周期（左右脚）触发一次脚步声；
## 停步/腾空/冻结输入时平滑回中（不改变相机朝向，调试相机直控不受影响——只动 position）
func _update_bob(delta: float) -> void:
	var speed := Vector2(velocity.x, velocity.z).length()
	var moving := speed > 0.5 and is_on_floor() and not ui_blocked and not is_in_dialog
	if moving:
		_bob_phase += delta * speed * TAU / BOB_STRIDE
		var step_index := int(floor(_bob_phase / PI))
		if step_index != _last_step_index:
			_last_step_index = step_index
			_step_count += 1
			_play_footstep()
		camera.position = _bob_rest + Vector3(
			sin(_bob_phase) * BOB_AMP_X,
			-absf(sin(_bob_phase)) * BOB_AMP_Y,
			0.0)
	else:
		camera.position = camera.position.lerp(_bob_rest, minf(1.0, delta * BOB_RETURN_SPEED))
		if speed <= 0.5:
			_bob_phase = 0.0

func _play_footstep() -> void:
	if _foot_player == null or _foot_player.stream == null:
		return
	# 左右脚轻微音高差（确定性交替，不引入随机源）
	_foot_player.pitch_scale = 0.97 if _step_count % 2 == 1 else 1.04
	_foot_player.play()

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
