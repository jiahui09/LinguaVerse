extends Node

## 全局游戏管理器（Autoload 单例）
## 管理游戏状态、设置、全局事件

signal game_started()
signal game_paused()
signal game_resumed()

var is_game_paused: bool = false
var settings: Dictionary = {
	"mouse_sensitivity": 0.002,
	"volume": 0.8,
	"fullscreen": false,
}

func _ready():
	# 暂停时也要能收到 ESC 恢复（否则暂停即软锁）
	process_mode = Node.PROCESS_MODE_ALWAYS

func _unhandled_input(event: InputEvent):
	# 全局暂停/恢复（对话中的 ESC 交给 dialog_manager 处理）
	if event.is_action_pressed("ui_cancel"):
		var dm = get_tree().get_first_node_in_group("dialog_manager")
		if dm != null and dm.has_method("is_dialog_active") and dm.is_dialog_active():
			return
		toggle_pause()

func toggle_pause():
	is_game_paused = not is_game_paused
	if is_game_paused:
		get_tree().paused = true
		game_paused.emit()
	else:
		get_tree().paused = false
		game_resumed.emit()

## 获取当前世界状态（供对话系统使用）
func get_world_state() -> Dictionary:
	return {
		"time_of_day": _get_time_of_day(),
		"player_position": _get_player_position(),
	}

func _get_time_of_day() -> String:
	var time = Time.get_time_dict_from_system()
	var hour = time.hour
	if hour >= 6 and hour < 8:
		return "dawn"
	elif hour >= 8 and hour < 17:
		return "day"
	elif hour >= 17 and hour < 20:
		return "dusk"
	else:
		return "night"

func _get_player_position() -> Vector3:
	var player = get_tree().get_first_node_in_group("player")
	if player:
		return player.global_position
	return Vector3.ZERO
