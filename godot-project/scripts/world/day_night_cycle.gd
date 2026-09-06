extends DirectionalLight3D

## 昼夜循环系统
## 游戏内时间与现实时间同步

@export var time_offset: float = 0.0  # 时区偏移（小时）

var current_hour: float = 0.0

func _ready():
	# 获取当前现实时间
	var time = Time.get_time_dict_from_system()
	current_hour = time.hour + time.minute / 60.0 + time_offset
	
	# 更新光照
	_update_light()

func _process(_delta: float):
	# 实时更新
	var time = Time.get_time_dict_from_system()
	current_hour = time.hour + time.minute / 60.0 + time_offset
	
	_update_light()

func _update_light():
	# 根据时间调整光照角度和颜色
	# 0:00 = 午夜（暗），6:00 = 日出，12:00 = 正午（亮），18:00 = 日落
	
	var sun_angle = (current_hour - 6.0) / 12.0 * PI  # 6点=地平线，12点=正上方
	rotation.x = -sun_angle
	
	# 光照强度
	var intensity = clamp(sin(sun_angle), 0.0, 1.0)
	light_energy = intensity
	
	# 光照颜色（日出/日落偏暖，正午偏白）
	var warmth = 1.0 - abs(current_hour - 12.0) / 6.0
	light_color = Color(1.0, lerp(0.95, 0.85, warmth), lerp(0.9, 0.7, warmth))

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
