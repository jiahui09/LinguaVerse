extends SceneTree

## 帧时间采样入口（P0-B5）
## 装载主场景，挂载 perf_sampler.gd 采样固定时长并出报告。
##
## 用法:
##   godot --headless --path godot-project -s res://scripts/debug/perf_drive.gd   # 逻辑耗时
##   godot --path godot-project -s res://scripts/debug/perf_drive.gd              # 真机(需显示环境)
##   LV_PERF_ENFORCE=1 上述真机运行 → 按 p95≤20ms/p99≤33ms 判定失败
## 产物: $LV_ARTIFACTS_DIR/perf.json（默认 godot-project/debug_artifacts/perf.json）

func _init():
	_run()

func _run():
	var scene: PackedScene = load("res://scenes/main.tscn")
	var main: Node = scene.instantiate()
	root.add_child(main)
	await process_frame
	await process_frame
	await process_frame

	var sampler = load("res://scripts/debug/perf_sampler.gd").new()
	sampler.setup(main.get_node("Sun"))
	main.add_child(sampler)
	# sampler 到时自行 get_tree().quit()，此处无需再等
