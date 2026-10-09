extends SceneTree

## 帧时间采样入口（P0-B5；P3 批次9 增加往返路线驱动）
## 装载主场景，沿 出生点→接缝1→走廊→接缝2→Vosges 街(拱廊对面) 原路折返，
## 全程挂 perf_sampler.gd 分段采样，走完（或失败）即收口并出报告。
##
## 用法:
##   godot --headless --path godot-project -s res://scripts/debug/perf_drive.gd   # 逻辑耗时
##   godot --path godot-project -s res://scripts/debug/perf_drive.gd              # 真机(需显示环境)
##   LV_PERF_ENFORCE=1 上述真机运行 → 按 p95≤20ms/p99≤33ms 判定失败
##   LV_PERF_SPEED=N 行进速度倍率（默认 1=游戏原速；verify 用 4 压缩时长——
##                  headless 逻辑耗时=每帧成本, 与行进速度无关, 只影响覆盖时长）
##   LV_PERF_TIMEOUT=秒 路线上限（默认 1200）
## 产物: $LV_ARTIFACTS_DIR/perf.json（含 route/segments 字段）

const ARRIVE_M := 2.5        # 到点容差
const STALL_SEC := 15.0      # 15s 位移 <1m = 卡住（提前失败，不空转到超时）
const STALL_M := 1.0

func _init():
	_run()

func _run():
	var scene: PackedScene = load("res://scenes/main.tscn")
	var main: Node = scene.instantiate()
	root.add_child(main)
	for i in 3:
		await physics_frame

	var player: Node3D = main.get_node("Player")
	var sun: Node = main.get_node("Sun")

	# 行进速度倍率（headless verify 压缩时长；真机验收保持 1 = 游戏原速）
	var speed_mult := OS.get_environment("LV_PERF_SPEED").to_float()
	if speed_mult <= 0.0:
		speed_mult = 1.0
	player.move_speed = player.move_speed * speed_mult

	var sampler = load("res://scripts/debug/perf_sampler.gd").new()
	sampler.setup(sun)
	# 保险上限：路线完成会提前 finish_route；驱动循环自己负责超时判定
	sampler.duration_sec = 1300.0
	main.add_child(sampler)
	sampler.begin_route()

	# ── 路线: 出生点 → 接缝1 → 走廊 → 接缝2 → Vosges(拱廊对面) → 原路折返 ──
	var vg: Node3D = root.find_child("StreetGeneratorVosges", true, false)
	var spawn := Vector3(player.global_position.x, 0.0, player.global_position.z)
	var seam1 := Vector3(0.0, 0.0, -89.01)   # 走廊接缝1（corridor placement.z；rosiers 局部=世界）
	var seam2 := Vector3(0.0, 0.0, -524.01)  # 走廊末端世界（corridor local z=435 实测中线 x≈0）
	var arcade: Vector3 = vg.to_global(Vector3(0.0, 0.0, 210.0))   # Vosges 中线·拱廊对面(s≈206.85)
	# [到达该点即结束的段名, 目标点]
	var wps: Array = [
		["rosiers_out", seam1],
		["corridor_out", seam2],
		["vosges_out", arcade],
		["vosges_back", seam2],
		["corridor_back", seam1],
		["rosiers_back", spawn],
	]

	print("[PerfDrive] route start=%v speed x%.1f (seam1=%v seam2=%v arcade=%v)" % [
		spawn, speed_mult, seam1, seam2, arcade,
	])
	sampler.mark_segment("rosiers_out")

	var elapsed := 0.0
	var step := 1.0 / float(Engine.physics_ticks_per_second)
	var timeout := OS.get_environment("LV_PERF_TIMEOUT").to_float()
	if timeout <= 0.0:
		timeout = 1200.0
	var fail_reason := ""
	var wi := 0
	var prev_pos: Vector3 = player.global_position
	var last_progress: Vector3 = player.global_position
	var stall_t := 0.0

	while wi < wps.size():
		await physics_frame
		elapsed += step
		var target: Vector3 = wps[wi][1]
		var flat := Vector3(target.x - player.global_position.x, 0.0, target.z - player.global_position.z)
		if flat.length() <= ARRIVE_M:
			if wi + 1 < wps.size():
				sampler.mark_segment(wps[wi + 1][0])
			wi += 1
			prev_pos = player.global_position
			last_progress = player.global_position
			stall_t = 0.0
			continue
		# 朝向目标 + 前进（yaw→rotation.y 同步语义见 playthrough _aim_at：控制器
		# 只在鼠标事件里同步 rotation，headless 必须手动双写）
		var cam: Camera3D = player.camera
		var from: Vector3 = cam.global_position if cam else player.global_position
		var dir: Vector3 = (Vector3(target.x, from.y + 0.6, target.z) - from).normalized()
		player.yaw = atan2(-dir.x, -dir.z)
		player.rotation.y = player.yaw
		Input.action_press("move_forward")

		var cur: Vector3 = player.global_position
		prev_pos = cur
		if cur.distance_to(last_progress) > STALL_M:
			last_progress = cur
			stall_t = 0.0
		else:
			stall_t += step
			if stall_t > STALL_SEC:
				fail_reason = "stuck at wp %d %v (pos=%v)" % [wi, target, cur]
				break
		if elapsed > timeout:
			fail_reason = "timeout %.0fs at wp %d/%d (pos=%v)" % [timeout, wi, wps.size(), cur]
			break
	Input.action_release("move_forward")

	# 路程按 waypoint 几何距离计（帧位移累计受物理步进/追帧影响，不作验收数字）
	var geo := 0.0
	var p := spawn
	for i in clampi(wi, 0, wps.size()):   # wi = 已完成的 waypoint 数
		geo += p.distance_to(wps[i][1])
		p = wps[i][1]

	if fail_reason.is_empty():
		print("[PerfDrive] route done meters=%.0f elapsed=%.0fs" % [geo, elapsed])
		sampler.finish_route(true, geo)
	else:
		print("[PerfDrive] FAIL: " + fail_reason)
		sampler.finish_route(false, geo, fail_reason)
