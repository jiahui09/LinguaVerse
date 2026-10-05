extends CharacterBody3D

## NPC 基类
## 所有 NPC 继承此脚本
##
## V1 视觉层（占位胶囊模型下的最小"活人感"，不加载任何外部资源，代码建节点）：
## - 名牌 + 职业副标题：billboard 常朝相机，超出 label_fade_distance 淡出
## - 台词气泡（Label3D）：对话中显示 NPC 最近一句话；等待 LLM 时显示省略点
## - 思考动作（决策 6）：身体左右轻晃 + 微仰头，配合气泡省略点，
##   让等待看起来像"在想怎么说"，而不是"系统在加载"
## - 点头反馈：回复到达时短暂点头（acknowledge）
## - 眼睛 + 眨眼：给胶囊一个朝向，转头/点头才看得出来
## - 对话中持续面向玩家；结束后恢复对话前的状态（决策 9：NPC 回到自己的行为）
##
## 注意：V1 的 NPC 是占位胶囊，思考动作是整体倾斜/点头，不是骨骼动画；
## 结构自检只验证状态与节点存在，"动作是否好看"必须由人目检。

@export var npc_name: String = "NPC"
@export var npc_job: String = ""
@export var npc_job_fr: String = ""   # 名牌副标题（法语职业，纯氛围信息，不承担教学语义）
@export var npc_personality: String = ""
@export var speaks_french: bool = true

## 名牌/副标题超过此距离（米）开始淡出，+4m 完全隐藏
@export var label_fade_distance: float = 16.0

enum State { IDLE, WALK, INTERACT, TALKING }
var current_state: State = State.IDLE

# 对话相关
var is_in_conversation: bool = false
var is_thinking: bool = false   # 思考动作开关（DialogManager 在请求期间置位）
var conversation_history: Array = []

signal dialog_started(npc_name: String)
signal dialog_ended(npc_name: String)

const DOT_FRAMES := 3          # 思考省略点帧数（.  ..  ...）
const DOT_INTERVAL := 0.35     # 每帧秒数
const NOD_DURATION := 0.45     # 点头动作时长
const FADE_SPAN := 4.0         # 名牌淡出过渡距离

var _state_before_talk: State = State.IDLE
var _body: MeshInstance3D
var _name_label: Label3D
var _job_label: Label3D
var _bubble: Label3D
var _eyes: Node3D

var _name_base_color := Color.WHITE
var _anim_t: float = 0.0
var _blink_t: float = 3.0
var _blink_phase: float = -1.0
var _nod_t: float = 0.0
var _dot_t: float = 0.0
var _dot_index: int = 0
var _bubble_line: String = ""

func _ready():
	# 注册到 group，方便查找
	add_to_group("npc")
	_resolve_visuals()
	_setup_name_label()
	_setup_job_label()
	_setup_bubble()
	_setup_eyes()

func _resolve_visuals():
	_body = get_node_or_null("BodyMesh") as MeshInstance3D
	_name_label = get_node_or_null("NameLabel") as Label3D

## 名牌：billboard 常朝相机（NPC 会转身，否则名牌会背对玩家）
func _setup_name_label():
	if _name_label == null:
		return
	_name_label.text = npc_name
	_name_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_name_base_color = _name_label.modulate

## 职业副标题（法语），挂在名牌下方
func _setup_job_label():
	if _name_label == null or npc_job_fr.is_empty():
		return
	_job_label = Label3D.new()
	_job_label.name = "JobLabel"
	_job_label.text = npc_job_fr
	_job_label.font_size = maxi(16, int(round(_name_label.font_size * 0.6)))
	_job_label.outline_size = _name_label.outline_size
	_job_label.modulate = Color(0.86, 0.9, 0.95, 0.9)
	_job_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_job_label.position = _name_label.position + Vector3(0, -0.26, 0)
	add_child(_job_label)

## 台词气泡：挂在名牌上方，底对齐（文字向上生长，不会压住名牌）
func _setup_bubble():
	if _name_label == null:
		return
	_bubble = Label3D.new()
	_bubble.name = "Bubble"
	_bubble.font_size = _name_label.font_size
	_bubble.outline_size = _name_label.outline_size + 4
	_bubble.modulate = Color(1.0, 0.98, 0.93, 1.0)
	_bubble.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_bubble.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_bubble.width = 420.0
	_bubble.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_bubble.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_bubble.position = _name_label.position + Vector3(0, 0.5, 0)
	_bubble.visible = false
	add_child(_bubble)

## 眼睛：挂在 BodyMesh 上（随呼吸/点头/倾斜一起动），给胶囊一个可见朝向
func _setup_eyes():
	if _body == null:
		return
	_eyes = Node3D.new()
	_eyes.name = "Eyes"
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.08, 0.08, 0.1)
	mat.roughness = 0.35
	for side in [-1.0, 1.0]:
		var eye := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 0.045
		sphere.height = 0.09
		sphere.radial_segments = 10
		sphere.rings = 6
		eye.mesh = sphere
		eye.material_override = mat
		# Godot 前向是 -Z：眼睛放在头部（胶囊中线上段）朝 -Z 一侧
		eye.position = Vector3(side * 0.1, 0.3, -0.25)
		_eyes.add_child(eye)
	_body.add_child(_eyes)

func _physics_process(delta: float):
	_animate(delta)
	match current_state:
		State.IDLE:
			_idle_behavior()
		State.WALK:
			_walk_behavior()
		State.INTERACT:
			_interact_behavior()
		State.TALKING:
			_talking_behavior()

## ---------- 动画（呼吸 / 思考 / 点头 / 眨眼 / 气泡点 / 名牌淡出） ----------

func _animate(delta: float):
	_anim_t += delta

	# 呼吸：极轻微的纵向伸缩，避免"雕像感"
	if _body:
		_body.scale.y = 1.0 + sin(_anim_t * 1.9) * 0.006

	# 思考动作（决策 6）：左右轻晃 + 微仰头（像在斟酌怎么说）
	var sway_z := 0.0
	var tilt_x := 0.0
	if is_thinking:
		sway_z = sin(_anim_t * 4.6) * 0.05
		tilt_x = 0.03 + sin(_anim_t * 2.1) * 0.03

	# 点头：回复到达后的短促一次低头
	var nod := 0.0
	if _nod_t > 0.0:
		_nod_t = maxf(0.0, _nod_t - delta)
		var p := 1.0 - _nod_t / NOD_DURATION
		nod = -sin(p * PI) * 0.14

	if _body:
		var blend := minf(delta * 8.0, 1.0)
		_body.rotation.x = lerpf(_body.rotation.x, tilt_x + nod, blend)
		_body.rotation.z = lerpf(_body.rotation.z, sway_z, blend)

	# 眨眼（0.14s 一次，3~6.5s 随机间隔）
	if _eyes:
		_blink_t -= delta
		if _blink_phase < 0.0 and _blink_t <= 0.0:
			_blink_phase = 0.0
			_blink_t = randf_range(3.0, 6.5)
		if _blink_phase >= 0.0:
			_blink_phase += delta / 0.14
			if _blink_phase >= 1.0:
				_blink_phase = -1.0
				_eyes.scale.y = 1.0
			else:
				_eyes.scale.y = 1.0 - 0.9 * sin(_blink_phase * PI)

	# 思考省略点（气泡里 . → .. → ...）
	if is_thinking and _bubble:
		_dot_t += delta
		if _dot_t >= DOT_INTERVAL:
			_dot_t = 0.0
			_dot_index = (_dot_index + 1) % DOT_FRAMES
			_bubble.text = ".".repeat(_dot_index + 1)

	# 对话中持续面向玩家（含思考全程：他一直在听你说）
	if is_in_conversation:
		var player = get_tree().get_first_node_in_group("player")
		if player:
			var d: Vector3 = player.global_position - global_position
			# Node3D 前向 = -Z → 目标 yaw = atan2(-dx, -dz)
			rotation.y = lerp_angle(rotation.y, atan2(-d.x, -d.z), minf(delta * 5.0, 1.0))

	_update_label_fade()

## 名牌/副标题距离淡出（远处名牌只是噪声；气泡只在对话近距离出现，不做淡出）
func _update_label_fade():
	var alpha := 1.0
	var vp := get_viewport()
	var cam: Camera3D = vp.get_camera_3d() if vp else null
	if cam:
		var d := cam.global_position.distance_to(global_position)
		alpha = 1.0 - clampf((d - label_fade_distance) / FADE_SPAN, 0.0, 1.0)
	if _name_label:
		_name_label.modulate = Color(
			_name_base_color.r, _name_base_color.g, _name_base_color.b,
			_name_base_color.a * alpha)
	if _job_label:
		var c := _job_label.modulate
		_job_label.modulate = Color(c.r, c.g, c.b, 0.9 * alpha)

## ---------- 虚函数：子类重写 ----------

func _idle_behavior():
	pass

func _walk_behavior():
	pass

func _interact_behavior():
	pass

func _talking_behavior():
	pass

## ---------- 对话状态 ----------

## 开始对话（记录原状态，结束后回到原行为——决策 9）
func start_dialog():
	if not is_in_conversation:
		_state_before_talk = current_state
	is_in_conversation = true
	current_state = State.TALKING
	dialog_started.emit(npc_name)

## 结束对话（唯一出口由 DialogManager 调用：走开 / ESC / 外部）
func end_dialog():
	is_in_conversation = false
	is_thinking = false
	current_state = _state_before_talk
	_bubble_line = ""
	if _bubble:
		_bubble.visible = false
		_bubble.text = ""
	dialog_ended.emit(npc_name)

## ---------- 思考动作 / 台词气泡 API ----------

## 请求期间置位：进入思考动作（晃动 + 微仰头 + 气泡省略点）
func set_thinking(value: bool):
	if is_thinking == value:
		return
	is_thinking = value
	_dot_t = 0.0
	_dot_index = 0
	if _bubble == null:
		return
	if value:
		_bubble.text = "."
		_bubble.visible = true
	elif _bubble_line != "" and is_in_conversation:
		_bubble.text = _bubble_line   # 回到上一句台词（错误时也保持有人味）
	else:
		_bubble.visible = false

## 回复到达：短促点头
func acknowledge():
	_nod_t = NOD_DURATION

## 在气泡里显示 NPC 的一句话（招呼语 / 回复）
func show_line(text: String):
	_bubble_line = text
	if _bubble == null or is_thinking:
		return
	if is_in_conversation and text != "":
		_bubble.text = text
		_bubble.visible = true

func get_bubble_text() -> String:
	return _bubble.text if _bubble else ""

func is_bubble_visible() -> bool:
	return _bubble != null and _bubble.visible

func get_job_label_text() -> String:
	return _job_label.text if _job_label else ""

func is_thinking_active() -> bool:
	return is_thinking

## 获取 NPC 信息（用于 Prompt 组装）
func get_npc_info() -> Dictionary:
	return {
		"name": npc_name,
		"job": npc_job,
		"personality": npc_personality,
		"speaks_french": speaks_french,
		"position": global_position,
	}
