extends DirectionalLight3D

## 昼夜循环系统
## 游戏内时间与现实时间同步（决策 7「游戏内时间完全跟随现实时间」）
##
## 两种模式:
##   模式 A（默认 = 决策 7）: 环境变量 LV_FIXED_HOUR 为空 → fixed_hour 保持 -1,
##       游戏内时间完全跟随现实时间（+ time_offset），深夜就是深夜。
##   模式 B（演示/调试开关）: 环境变量 LV_FIXED_HOUR 设为 0–23.99 的浮点数,
##       _ready() 读到后写入 fixed_hour 锁定该时段并 print 一行提示。
##       用法: LV_FIXED_HOUR=14.5 ./tools/Godot_v4.7.2-stable_linux.x86_64 --path godot-project
##             LV_FIXED_HOUR=21.0 ./tools/Godot_v4.7.2-stable_linux.x86_64 --headless \
##                 --path godot-project -s res://scripts/debug/xxx.gd
##             （bash 里 export LV_FIXED_HOUR=21.0 亦可；非法/越界值会被忽略并提示）
##
## 接口约定: @export fixed_hour 保留, 场景文件不再写死数值(main.tscn 演示锁已删),
##   代码直接赋值 `sun.fixed_hour = 21.0` 始终有效(debug 脚本依赖此接口)。

@export var time_offset: float = 0.0  # 时区偏移（小时）
@export var fixed_hour: float = -1.0  # -1 = 跟随现实时间；0-23.99 = 固定时段

var current_hour: float = 0.0

## ── 昼夜联动缓存（诊断→优化方案 §3：每帧轮询改为"变化才下发"）──
## _gens：街景生成器快照，每 30 帧刷新一次（不再每帧查组）
## _last_glow/_gens_sig：夜光档位 + 就绪签名，二者都没变就不下发
var _gens: Array = []
var _gens_tick: int = -1000
var _last_glow: float = NAN
var _gens_sig: String = "?"
## 太阳属性上次写入时刻（角度/能量/颜色按 0.005h≈18s 门槛写，肉眼无感）
var _last_light_hour: float = NAN
## 时间读取节流：OS 时间+字典分配由每帧一次 → 每 0.5s 一次
const TIME_REFRESH_INTERVAL := 0.5
var _time_accum: float = 1.0
## 太阳属性写入门槛 ≈18 秒（太阳角 0.075°，肉眼不可见）
const LIGHT_HOUR_EPSILON := 0.005
## 夜光生成器组快照刷新频率（帧）
const GENS_REFRESH_FRAMES := 30

func _ready():
	_apply_demo_time_override()  # 环境变量演示开关（见头注释两种模式）
	# 获取当前现实时间（或固定时间）
	_update_time()
	# 更新光照
	_update_light()

## 读环境变量 LV_FIXED_HOUR: 空 → 不设（跟随现实时间, 模式 A）
## 有效浮点且在 0–23.99 → 锁定演示时段（模式 B）并打印提示
func _apply_demo_time_override():
	var env := OS.get_environment("LV_FIXED_HOUR")
	if env.is_empty():
		return  # 模式 A: 跟随现实时间（决策 7）
	if not env.is_valid_float():
		print("[DayNight] LV_FIXED_HOUR 非法(非浮点), 忽略: ", env)
		return
	var h := float(env)
	if h < 0.0 or h > 23.99:
		print("[DayNight] LV_FIXED_HOUR 超出 0-23.99, 忽略: ", env)
		return
	fixed_hour = h
	print("[DayNight] 演示模式: LV_FIXED_HOUR=", env, " → fixed_hour=", fixed_hour)

func _process(delta: float):
	# 实时更新（优化：OS 时间字典分配由每帧 → 0.5s 一次；
	# 一昼夜只推进 0.5/3600 小时，对角度/光照无可见影响，
	# 直接调用 _update_time()/_update_light() 的测试路径语义不变）
	_time_accum += delta
	if _time_accum < TIME_REFRESH_INTERVAL:
		return
	_time_accum = 0.0
	_update_time()
	_update_light()

func _update_time():
	if fixed_hour >= 0.0:
		current_hour = fixed_hour
	else:
		var time = Time.get_time_dict_from_system()
		current_hour = time.hour + time.minute / 60.0 + time_offset

func _update_light():
	# 根据时间调整光照角度和颜色
	# 0:00 = 午夜（暗），6:00 = 日出，12:00 = 正午（亮），18:00 = 日落

	# 1) 夜光档位（幂等，只在档位/生成器就绪状态变化时下发）
	var glow := 0.0
	if current_hour < 6.0 or current_hour >= 20.0:
		glow = 0.75
	elif current_hour < 8.0 or current_hour >= 17.5:
		glow = 0.35
	_apply_night_glow(glow)

	# 2) 太阳角度/能量/颜色：变化 <0.005h（≈18 秒，角度 0.075°）不写属性。
	#    测试里直接改 fixed_hour（如 14.5→21.0）差值远大于门槛 → 立即生效。
	if not is_nan(_last_light_hour) \
			and absf(current_hour - _last_light_hour) < LIGHT_HOUR_EPSILON:
		return
	_last_light_hour = current_hour

	var sun_angle = (current_hour - 6.0) / 12.0 * PI  # 6点=地平线，12点=正上方
	rotation.x = -sun_angle

	# 光照强度
	var intensity = clamp(sin(sun_angle), 0.0, 1.0)
	light_energy = intensity * 1.4 + 0.05  # 底部最低 5% 防止全黑

	# 光照颜色（日出/日落偏暖，正午偏白）
	var warmth = 1.0 - abs(current_hour - 12.0) / 6.0
	light_color = Color(1.0, lerp(0.95, 0.85, warmth), lerp(0.9, 0.7, warmth))

## 夜光档位下发：全组街区（P3 批次2 多街回归修复：原实现
## get_first_node_in_group 只联动第一个生成器 → Vosges/走廊夜里永远不亮）。
## 只在（档位 or 生成器就绪签名）变化时遍历下发；组查询每 30 帧一次。
func _apply_night_glow(glow: float) -> void:
	var now_tick := Engine.get_process_frames()
	if _gens.is_empty() or now_tick - _gens_tick >= GENS_REFRESH_FRAMES:
		_gens_tick = now_tick
		_gens = get_tree().get_nodes_in_group("street_generator")
	var total := 0
	var ready_n := 0
	for gen in _gens:
		if is_instance_valid(gen):
			total += 1
			if gen.is_node_ready():
				ready_n += 1
	var sig := "%d/%d" % [ready_n, total]
	if not is_nan(_last_glow) and is_equal_approx(_last_glow, glow) and sig == _gens_sig:
		return
	for gen in _gens:
		if is_instance_valid(gen) and gen.is_node_ready() \
				and gen.has_method("set_night_glow"):
			gen.set_night_glow(glow)
	_last_glow = glow
	_gens_sig = sig

## 当前夜光档位（测试/调试读取）
func get_night_glow() -> float:
	return 0.0 if is_nan(_last_glow) else _last_glow

## 夜光联动覆盖到的街区生成器数（测试断言用）
func glow_coverage() -> int:
	var n := 0
	for gen in _gens:
		if is_instance_valid(gen):
			n += 1
	return n

## 获取当前时间描述
func get_time_of_day() -> String:
	if current_hour >= 6 and current_hour < 8:
		return "dawn"
	elif current_hour >= 8 and current_hour < 17:
		return "day"
	elif current_hour >= 17 and current_hour < 20:
		return "dusk"
	else:
		return "night"

## 获取格式化时间字符串
func get_time_string() -> String:
	var hour = int(current_hour) % 24
	var minute = int((current_hour - int(current_hour)) * 60)
	return "%02d:%02d" % [hour, minute]
