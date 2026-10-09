extends Node

## 帧时间逐帧采样器（P0-B5）— 由 perf_drive.gd 挂载
## 采样 duration_sec 后计算 p50/p95/p99/max，写 JSON 并结束场景。
##
## scope 诚实性：headless 模式只含逻辑/物理耗时，不含 GPU 渲染；
## 阈值门禁(p95≤20ms/p99≤33ms)仅在 LV_PERF_ENFORCE=1 时生效（真机验收用）。
##
## P3 批次9 路线模式：perf_drive 沿 出生点→走廊→Vosges 往返 驱动玩家，
## 到达终点调 finish_route()（提前收口，不等 duration_sec）；
## mark_segment(name) 在当前帧开新段，report["segments"] 出每段 p50/p95。

@export var duration_sec: float = 8.0
@export var out_dir: String = ""

var _samples: Array[float] = []
var _elapsed: float = 0.0
var _cycle_t: float = 0.0
var _sun: Node = null
# ── 路线模式状态（批次9）──
var _segments: Array = [["init", 0]]   # [[name, start_idx], ...]
var _route_ok: bool = false
var _route_completed: bool = false
var _route_meters: float = 0.0
var _route_reason: String = ""
var _route_active: bool = false

func setup(sun: Node) -> void:
	_sun = sun

## 路线模式: 采样上限交给路线完成事件（duration_sec 仍作保险上限）
func begin_route() -> void:
	_route_active = true

func mark_segment(name: String) -> void:
	_segments.append([name, _samples.size()])

func finish_route(ok: bool, meters: float, reason: String = "") -> void:
	_route_completed = true
	_route_ok = ok
	_route_meters = meters
	_route_reason = reason
	_finish()

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

func _stats_of(sorted: Array) -> Dictionary:
	var total := 0.0
	for s in sorted:
		total += s
	return {
		"count": sorted.size(),
		"mean_ms": snappedf(total / maxf(1.0, float(sorted.size())), 0.01),
		"p50_ms": snappedf(_percentile(sorted, 50.0), 0.01),
		"p95_ms": snappedf(_percentile(sorted, 95.0), 0.01),
		"p99_ms": snappedf(_percentile(sorted, 99.0), 0.01),
		"max_ms": snappedf(sorted[sorted.size() - 1] if not sorted.is_empty() else 0.0, 0.01),
		"fps_avg": snappedf(Engine.get_frames_per_second(), 1),
	}

func _percentile(sorted: Array, p: float) -> float:
	if sorted.is_empty():
		return 0.0
	var idx := clampi(ceili(p / 100.0 * sorted.size()) - 1, 0, sorted.size() - 1)
	return sorted[idx]

func _finish() -> void:
	var sorted := _samples.duplicate()
	sorted.sort()
	var stats := _stats_of(sorted)

	# 路线分段统计（批次9）: 每段 = [start_i, start_{i+1})
	var seg_stats := {}
	for i in _segments.size():
		var name: String = _segments[i][0]
		var a: int = _segments[i][1]
		var b: int = _segments[i + 1][1] if i + 1 < _segments.size() else _samples.size()
		if b <= a:
			continue
		var part := _samples.slice(a, b)
		part.sort()
		seg_stats[name] = _stats_of(part)

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
		"duration_sec": snappedf(_elapsed, 0.01),
		"headless": headless,
		"renderer": str(ProjectSettings.get_setting("rendering/renderer/rendering_method", "")),
		"scope": scope,
		"thresholds_enforced": enforce,
		"stats": stats,
		"segments": seg_stats,
	}
	if _route_active:
		report["route"] = {
			"completed": _route_completed,
			"ok": _route_ok,
			"meters": snappedf(_route_meters, 0.1),
			"reason": _route_reason,
		}

	# 门禁：①真机阈值（显式要求时）②路线未走完 = 失败（批次9 判据）
	var failed := false
	var reasons: Array = []
	if _route_active and (not _route_completed or not _route_ok):
		failed = true
		reasons.append("route: " + ("未完成" if not _route_completed else _route_reason))
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
	if _route_active:
		print("[PerfDrive] ROUTE completed=%s ok=%s meters=%.0f %s" % [
			_route_completed, _route_ok, _route_meters, _route_reason,
		])
		for seg_name in seg_stats:
			var ss: Dictionary = seg_stats[seg_name]
			print("[PerfDrive] SEG %s count=%d p50=%.2f p95=%.2f" % [
				seg_name, ss["count"], ss["p50_ms"], ss["p95_ms"],
			])
	if failed:
		for r in reasons:
			print("[PerfDrive] FAIL: " + r)
	get_tree().quit(1 if failed else 0)
