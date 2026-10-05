extends Node

## 帧时间逐帧采样器（P0-B5）— 由 perf_drive.gd 挂载
## 采样 duration_sec 后计算 p50/p95/p99/max，写 JSON 并结束场景。
##
## scope 诚实性：headless 模式只含逻辑/物理耗时，不含 GPU 渲染；
## 阈值门禁(p95≤20ms/p99≤33ms)仅在 LV_PERF_ENFORCE=1 时生效（真机验收用）。

@export var duration_sec: float = 8.0
@export var out_dir: String = ""

var _samples: Array[float] = []
var _elapsed: float = 0.0
var _cycle_t: float = 0.0
var _sun: Node = null

func setup(sun: Node) -> void:
	_sun = sun

func _process(delta: float) -> void:
	_elapsed += delta
	_samples.append(delta * 1000.0)

	# 激活昼夜联动路径（窗光每 10 帧联动一次 set_night_glow）
	_cycle_t += delta
	if _sun != null and _cycle_t >= 2.0:
		_cycle_t = 0.0
		_sun.fixed_hour = 14.5 if _sun.fixed_hour > 18.0 else 21.0
		_sun._update_time()
		_sun._update_light()

	if _elapsed >= duration_sec:
		_finish()

func _percentile(sorted: Array, p: float) -> float:
	if sorted.is_empty():
		return 0.0
	var idx := clampi(ceili(p / 100.0 * sorted.size()) - 1, 0, sorted.size() - 1)
	return sorted[idx]

func _finish() -> void:
	var sorted := _samples.duplicate()
	sorted.sort()
	var total := 0.0
	for s in sorted:
		total += s
	var stats := {
		"count": sorted.size(),
		"mean_ms": snappedf(total / maxf(1.0, float(sorted.size())), 0.01),
		"p50_ms": snappedf(_percentile(sorted, 50.0), 0.01),
		"p95_ms": snappedf(_percentile(sorted, 95.0), 0.01),
		"p99_ms": snappedf(_percentile(sorted, 99.0), 0.01),
		"max_ms": snappedf(sorted[sorted.size() - 1] if not sorted.is_empty() else 0.0, 0.01),
		"fps_avg": snappedf(Engine.get_frames_per_second(), 1),
	}

	var headless := DisplayServer.get_name() == "headless"
	var enforce := OS.get_environment("LV_PERF_ENFORCE") == "1"
	var scope: String
	if headless:
		scope = "headless：仅逻辑/物理帧耗时，不含 GPU 渲染与窗口合成；不能据此声称真机帧率达标"
	else:
		scope = "带显示运行：含渲染帧耗时"

	var report := {
		"tool": "perf_drive",
		"generated_at": Time.get_datetime_string_from_system(true, true),
		"duration_sec": duration_sec,
		"headless": headless,
		"renderer": str(ProjectSettings.get_setting("rendering/renderer/rendering_method", "")),
		"scope": scope,
		"thresholds_enforced": enforce,
		"stats": stats,
	}

	# 门禁：仅在显式要求（真机）时按 p95≤20ms / p99≤33ms 判定
	var failed := false
	var reasons: Array = []
	if enforce:
		if stats["p95_ms"] > 20.0:
			failed = true
			reasons.append("p95=%.2fms > 20ms" % stats["p95_ms"])
		if stats["p99_ms"] > 33.0:
			failed = true
			reasons.append("p99=%.2fms > 33ms" % stats["p99_ms"])
	report["ok"] = not failed
	report["failures"] = reasons

	var dir := out_dir
	if dir == "":
		dir = OS.get_environment("LV_ARTIFACTS_DIR")
		if dir == "":
			dir = ProjectSettings.globalize_path("res://debug_artifacts")
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(dir.path_join("perf.json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(report, "  ") + "\n")
		f.close()
		print("[PerfDrive] 写入 %s" % dir.path_join("perf.json"))
	print("[PerfDrive] count=%d mean=%.2fms p50=%.2f p95=%.2f p99=%.2f max=%.2f (headless=%s enforced=%s)" % [
		stats["count"], stats["mean_ms"], stats["p50_ms"], stats["p95_ms"], stats["p99_ms"], stats["max_ms"], headless, enforce,
	])
	if failed:
		for r in reasons:
			print("[PerfDrive] FAIL: " + r)
	get_tree().quit(1 if failed else 0)
