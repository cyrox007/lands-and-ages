extends RefCounted
## Общий испытательный маршрут для headless CI и реального устройства.
## Сценарий один; результат JSON пригоден для сравнения внутри платформы.

const Route = preload("res://scripts/world_benchmark_route.gd")
const Metrics = preload("res://scripts/world_benchmark_metrics.gd")


func run(view: Node3D) -> Dictionary:
	var snapshot: Dictionary = view._world_model.to_data()
	view._prepare_benchmark_start()
	var config: RefCounted = view._world_model.config
	var points: Array[Dictionary] = Route.samples(config.width, config.height)
	var phases: Array[Dictionary] = []
	var intervals: Array[float] = []
	var recorder := Metrics.new()
	var phase := ""
	var last_tick := Time.get_ticks_usec()

	for point in points:
		var name: String = point["phase"]
		if name != phase:
			if not phase.is_empty():
				phases.append(recorder.finish(view))
			recorder.begin(name, view)
			phase = name
		var target: Vector2 = point["center"]
		var zoom: float = point["zoom"]
		if not is_equal_approx(view._camera.size, zoom):
			view._change_zoom(zoom / view._camera.size)
		if view._center.distance_squared_to(target) > 0.000001:
			view._move_center(target - view._center)
		await view.get_tree().process_frame
		var tick := Time.get_ticks_usec()
		var interval := float(tick - last_tick) / 1000.0
		last_tick = tick
		intervals.append(interval)
		recorder.record(view, interval)

	if not phase.is_empty():
		phases.append(recorder.finish(view))

	var built := 0
	var hits := 0
	var evictions := 0
	var fast_rejects := 0
	var precise_checks := 0
	var peak_pending := 0
	var peak_static := 0
	var peak_cache := 0
	var ground_cpu_ms := 0.0
	var water_cpu_ms := 0.0
	for result in phases:
		built += int(result["chunks_built"])
		hits += int(result["cache_hits"])
		evictions += int(result["cache_evictions"])
		fast_rejects += int(result["visibility_fast_rejects"])
		precise_checks += int(result["visibility_precise_checks"])
		peak_pending = maxi(peak_pending, int(result["peak_pending_chunks"]))
		peak_static = maxi(peak_static, int(result["peak_godot_static_bytes"]))
		peak_cache = maxi(peak_cache, int(result["peak_cached_geometry_bytes"]))
		ground_cpu_ms += float(result["ground_mesh_cpu_ms_total"])
		water_cpu_ms += float(result["water_mesh_cpu_ms_total"])

	var dimensions: Vector2 = view.get_viewport().get_visible_rect().size
	return {
		"schema_version": 1,
		"stage": "8.8",
		"route_version": Route.VERSION,
		"route_frames": points.size(),
		"engine": Engine.get_version_info().get("string", "unknown"),
		"platform": OS.get_name(),
		"render_backend": DisplayServer.get_name(),
		"render_method": ProjectSettings.get_setting(
			"rendering/renderer/rendering_method", "compatibility"),
		"headless": DisplayServer.get_name() == "headless",
		"viewport": {"width": int(dimensions.x), "height": int(dimensions.y)},
		"units": {
			"interval_ms": "интервал между кадрами игрового цикла",
			"build_frame_ms": "время построения мешей CPU",
			"peak_visibility_ms": "время одного обновления видимости CPU",
			"peak_cached_geometry_bytes": "оценка буферов вершин/индексов",
			"ground_mesh_cpu_ms_total": "построение геометрии земли на CPU, не GPU",
			"water_mesh_cpu_ms_total": "построение геометрии воды на CPU, не GPU",
			"peak_godot_static_bytes": "статическая память Godot, не RAM/VRAM"
		},
		"map": {
			"width": config.width, "height": config.height,
			"seed": config.seed, "chunk_size": config.chunk_size
		},
		"summary": {
			"interval_ms_p50": Metrics.percentile(intervals, 0.50),
			"interval_ms_p95": Metrics.percentile(intervals, 0.95),
			"interval_ms_p99": Metrics.percentile(intervals, 0.99),
			"chunks_built": built,
			"cache_hits": hits,
			"cache_evictions": evictions,
			"visibility_fast_rejects": fast_rejects,
			"visibility_precise_checks": precise_checks,
			"peak_pending_chunks": peak_pending,
			"ground_mesh_cpu_ms_total": ground_cpu_ms,
			"water_mesh_cpu_ms_total": water_cpu_ms,
			"peak_cached_geometry_bytes": peak_cache,
			"peak_godot_static_bytes": peak_static,
			"pending_after_route": view._pending.size(),
			"physics_unchanged": view._world_model.to_data() == snapshot
		},
		"phases": phases
	}
