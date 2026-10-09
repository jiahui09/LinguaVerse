extends CharacterBody3D

## NPC 基类
## 所有 NPC 继承此脚本
##
## P3 批次8 视觉层（决策 27 模型化，弃胶囊+球眼）：
## - Model = 6 部件 GLB（Head/Torso/ArmL/ArmR/LegL/LegR，关节枢轴已在建模时归位）
## - 名牌/副标题/气泡/思考/点头/面向玩家等机制不变，动作挂点从胶囊迁到 Model/Head
## - 步行摆动 = 程序摆动（决策 27 骨骼时间盒的降级路线，边界如实记录）：
##   WALK 时四肢绕肩/髋反相摆 + 躯干微起伏；IDLE/对话回正
## - 眨眼机制随球眼移除（贴片眼无独立眼睑，如实记录为已知简化）
##
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
const LABEL_ALPHA_EPSILON := 0.005   # 名牌 alpha 写入门槛（<1% 步进不可见）

var _state_before_talk: State = State.IDLE
var _has_met_player: bool = false   # 决策 14：NPC 实例生命周期内记住是否聊过
var _body: Node3D                  # P3 批次8: GLB 模型根（决策 27 模型化）
var _head: Node3D                  # 点头只动头（枢轴=颈，GLB 建模时已归位）
var _arm_l: Node3D
var _arm_r: Node3D
var _leg_l: Node3D
var _leg_r: Node3D
var _walk_phase: float = 0.0
var _name_label: Label3D
var _job_label: Label3D
var _bubble: Label3D

var _name_base_color := Color.WHITE
var _anim_t: float = 0.0
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

func _resolve_visuals():
	_body = get_node_or_null("Model") as Node3D
	_name_label = get_node_or_null("NameLabel") as Label3D
	if _body:
		_head = _body.get_node_or_null("Head") as Node3D
		_arm_l = _body.get_node_or_null("ArmL") as Node3D
		_arm_r = _body.get_node_or_null("ArmR") as Node3D
		_leg_l = _body.get_node_or_null("LegL") as Node3D
		_leg_r = _body.get_node_or_null("LegR") as Node3D

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

## P3 批次8：球眼随胶囊一并移除（决策 27 模型化）——眼窝/鼻/发已在 GLB 的 Head 部件里。

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

	# 点头：回复到达后的短促一次低头（只动 Head，枢轴在颈）
	var nod := 0.0
	if _nod_t > 0.0:
		_nod_t = maxf(0.0, _nod_t - delta)
		var p := 1.0 - _nod_t / NOD_DURATION
		nod = -sin(p * PI) * 0.14

	if _body:
		var blend := minf(delta * 8.0, 1.0)
		_body.rotation.x = lerpf(_body.rotation.x, tilt_x, blend)
		_body.rotation.z = lerpf(_body.rotation.z, sway_z, blend)
		if _head:
			_head.rotation.x = lerpf(_head.rotation.x, nod, blend)

	# 程序摆动（决策 27 时间盒降级）：WALK 反相摆四肢，其余状态回正
	_animate_walk(delta)

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

## 步行摆动（决策 27：骨骼动画时间盒超时的降级路线——程序摆动，边界如实记录）
## 左腿前迈与右臂同相（对侧摆臂），枢轴已在 GLB 建模时归到肩/髋。
func _animate_walk(delta: float):
	var blend := minf(delta * 8.0, 1.0)
	var moving := current_state == State.WALK
	if moving:
		_walk_phase += delta * 9.5     # ≈1.5Hz 步频（1.2m/s ÷ 0.8m 步幅）
	else:
		_walk_phase = 0.0
	var sw := 0.55 if moving else 0.0
	var s := sin(_walk_phase)
	_part_swing(_arm_l, -s * sw, blend)
	_part_swing(_arm_r, s * sw, blend)
	_part_swing(_leg_l, s * sw * 1.1, blend)
	_part_swing(_leg_r, -s * sw * 1.1, blend)
	# 躯干随步起伏（仅行走；站定回 0）
	if _body:
		var bob := absf(sin(_walk_phase * 2.0)) * 0.014 if moving else 0.0
		_body.position.y = lerpf(_body.position.y, bob, blend)

func _part_swing(part: Node3D, target_x: float, blend: float):
	if part:
		part.rotation.x = lerpf(part.rotation.x, target_x, blend)

## 名牌/副标题距离淡出（远处名牌只是噪声；气泡只在对话近距离出现，不做淡出）
## 诊断→优化方案 §3：原实现每 tick 无条件写 modulate（5 NPC × 60Hz =
## 300 次/秒 Color 构造 + CanvasItem 重绘通知）。改为 alpha 变化 ≥0.005 才写，
## 远处（alpha 已 0）与贴近时稳态零写；观感步进 <1% 不可见。
var _label_alpha_cache: float = -1.0

func _update_label_fade():
	if _name_label == null and _job_label == null:
		return
	var alpha := 1.0
	var vp := get_viewport()
	var cam: Camera3D = vp.get_camera_3d() if vp else null
	if cam:
		var d := cam.global_position.distance_to(global_position)
		alpha = 1.0 - clampf((d - label_fade_distance) / FADE_SPAN, 0.0, 1.0)
	if absf(alpha - _label_alpha_cache) < LABEL_ALPHA_EPSILON:
		return
	_label_alpha_cache = alpha
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
	_has_met_player = true   # 二次招呼记忆（决策 14 升级）：下次见面认得出你
	dialog_started.emit(npc_name)

## 是否见过玩家（DialogManager 据此选择初次/记忆招呼语）
func has_met_player() -> bool:
	return _has_met_player

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
