extends Node

## 环境音（P1-5 / 决策 10）：街道循环 + 咖啡馆室内循环，按玩家区域交叉淡变。
##
## - 素材：程序合成 CC0（本仓库 tools/make_ambience.py 生成，无第三方素材）
## - 循环：AudioStreamWAV LOOP_FORWARD，素材本身首尾交叉淡化过（check_audio 校验）
## - 区域判定：+X 侧立面在 x≈5.91，玩家越过 x>6 必然是进了咖啡馆室内
##   （其余位置 x>6 被建筑碰撞挡住，不可能到达），不依赖 tag/区域触发器
## - 素材缺失或未导入时静默跳过并打印一行，绝不阻断游戏
## - 只有循环环境音；点单杯碟声在 npc_waiter.gd 里按需播放

const STREET_WAV := "res://assets/audio/ambient/street_loop.wav"
const CAFE_WAV := "res://assets/audio/ambient/cafe_loop.wav"
const CAFE_INTERIOR_X := 6.0   # 室内分界（立面 x=5.91，玩家可站的位置里 >6 即室内）
const FADE_SPEED := 1.8        # 线性增益每秒过渡量（0.55s 内完成整段淡变）
const MUTE_GAIN := 0.0001      # ≈ -80 dB

var _street: AudioStreamPlayer
var _cafe: AudioStreamPlayer
var _street_gain := 0.0
var _cafe_gain := 0.0
## 诊断→优化方案 §3：玩家引用缓存 + 收敛后零写。
## 原实现每帧 1 次组查询（数组分配）+ 2 次 volume_db 写（音量已收敛也在写）。
var _player: Node
var _zone_cafe := false      # 上次判定的区域
var _settled := false        # 增益已达目标 → 本轮可整帧跳过

func _ready():
	_street = _make_loop_player("StreetAmbience", STREET_WAV, 0.0)
	_cafe = _make_loop_player("CafeAmbience", CAFE_WAV, MUTE_GAIN)

func _make_loop_player(node_name: String, path: String, gain: float) -> AudioStreamPlayer:
	if not ResourceLoader.exists(path):
		print("[Ambience] 缺少音频素材，跳过: ", path)
		return null
	var stream = load(path)
	if stream is AudioStreamWAV:
		var wav: AudioStreamWAV = stream
		# 16-bit mono：data 每帧 2 字节 → loop_end = 总帧数（全曲循环）
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = wav.data.size() / 2
	var p := AudioStreamPlayer.new()
	p.name = node_name
	p.stream = stream
	p.volume_db = _gain_to_db(gain)
	add_child(p)
	p.play()
	return p

func _process(delta: float):
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player")
	var want_cafe := false
	if _player != null:
		want_cafe = _player.global_position.x > CAFE_INTERIOR_X
	# 收敛且区域未变 → 不查组、不写 volume_db（稳态零开销）
	if _settled and want_cafe == _zone_cafe:
		return
	_zone_cafe = want_cafe
	var target_cafe := 1.0 if want_cafe else 0.0
	var target_street := 0.0 if want_cafe else 1.0
	var old_street := _street_gain
	var old_cafe := _cafe_gain
	_street_gain = _move_toward_gain(_street_gain, target_street, delta)
	_cafe_gain = _move_toward_gain(_cafe_gain, target_cafe, delta)
	_settled = _street_gain == old_street and _cafe_gain == old_cafe
	if _settled:
		return   # 增益没动 → 不写属性（值本来就是上一次写进去的）
	if _street:
		_street.volume_db = _gain_to_db(_street_gain)
	if _cafe:
		_cafe.volume_db = _gain_to_db(_cafe_gain)

func _move_toward_gain(current: float, target: float, delta: float) -> float:
	var step := FADE_SPEED * delta
	if absf(current - target) <= step:
		return target
	return current + step if target > current else current - step

func _gain_to_db(gain: float) -> float:
	return linear_to_db(maxf(gain, MUTE_GAIN))

## 调试/断言用：当前是否在放街道音、目标区域是否室内
func is_street_playing() -> bool:
	return _street != null and _street.playing

func is_cafe_loaded() -> bool:
	return _cafe != null and _cafe.stream != null

func get_gains() -> Array:
	return [_street_gain, _cafe_gain]
