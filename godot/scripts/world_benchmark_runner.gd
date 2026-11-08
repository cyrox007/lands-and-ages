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
	var peak_nature_chunks := 0
	var peak_nature_shapes := 0
	var peak_cache := 0
	var ground_cpu_ms := 0.0
	var ground_prepare_ms := 0.0
	var ground_upload_ms := 0.0
	var water_cpu_ms := 0.0
	for result in phases:
		built += int(result["chunks_built"])
		hits += int(result["cache_hits"])
		evictions += int(result["cache_evictions"])
		fast_rejects += int(result["visibility_fast_rejects"])
		precise_checks += int(result["visibility_precise_checks"])
		peak_pending = maxi(peak_pending, int(result["peak_pending_chunks"]))
		peak_static = maxi(peak_static, int(result["peak_godot_static_bytes"]))
		peak_nature_chunks = maxi(peak_nature_chunks,
			int(result["collision_chunks_at_phase_end"]))
		peak_nature_shapes = maxi(peak_nature_shapes,
			int(result["collision_shapes_at_phase_end"]))
		peak_cache = maxi(peak_cache, int(result["peak_cached_geometry_bytes"]))
		ground_cpu_ms += float(result["ground_mesh_cpu_ms_total"])
		ground_prepare_ms += float(result["ground_prepare_worker_ms_total"])
		ground_upload_ms += float(result["ground_upload_main_ms_total"])
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
			"ground_prepare_worker_ms_total": "CPU-расчёт массивов в WorkerThreadPool",
			"ground_upload_main_ms_total": "создание ArrayMesh на главном потоке",
			"peak_godot_static_bytes": "статическая память Godot, не RAM/VRAM",
			"peak_nature_collision_shapes_sampled": "максимум форм в конце фаз; не все кадры"
		},
		"map": {
			"width": config.width, "height": config.height,
			"seed": config.world_seed, "chunk_size": config.chunk_size
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
			"ground_prepare_worker_ms_total": ground_prepare_ms,
			"ground_upload_main_ms_total": ground_upload_ms,
			"water_mesh_cpu_ms_total": water_cpu_ms,
			"peak_cached_geometry_bytes": peak_cache,
			"peak_godot_static_bytes": peak_static,
			"peak_nature_collision_chunks_sampled": peak_nature_chunks,
			"peak_nature_collision_shapes_sampled": peak_nature_shapes,
			"pending_after_route": view._pending.size() +
				view._chunk_jobs.size(),
			"physics_unchanged": view._world_model.to_data() == snapshot
		},
		"phases": phases
	}


func run_landscape(view: Node3D) -> Dictionary:
	# Отдельный аппаратный маршрут RF4: камера и настройки остаются
	# настоящими игровыми, а физические воздействия проходят через
	# тот же LandscapeEvents и WorldDayRunner, что ручные команды.
	# В отличие от маршрута 8.8, изменения мира здесь ожидаемы.
	var route: Array[Dictionary] = [
		{"kind": "кратер", "offset": Vector2.ZERO,
			"radius": 9.0, "strength": 2.0},
		{"kind": "оползень", "offset": Vector2(-6.0, 0.0),
			"radius": 8.0, "strength": 0.8},
		{"kind": "просадка", "offset": Vector2(6.0, 1.0),
			"radius": 6.0, "strength": 1.5}
	]
	var center := Vector2(view._world_model.config.width,
		view._world_model.config.height) * 0.5
	var original_revision: int = view._world_model.revision
	var results: Array[Dictionary] = []
	for entry in route:
		# Не измеряем работу с устаревшими чанками: сначала
		# завершаем предыдущую очередь, затем начинаем новый удар.
		view._wait_chunk_jobs()
		var position: Vector2 = center + entry["offset"]
		var kind: String = entry["kind"]
		var start := Time.get_ticks_usec()
		var changed: Dictionary = view._landscape_events.apply(
			kind, position, entry["radius"], entry["strength"])
		if changed.is_empty():
			results.append({"kind": kind, "applied": false})
			continue
		var impact: Dictionary = view._nature.apply_landscape_impact(
			kind, position, entry["radius"], 1.0, view._climate.day)
		view._flush_world_changes()
		# Аппаратный маршрут — настоящие природные события: помимо
		# рельефа оставляем долгоживущий след в почве. Его физическая
		# ревизия и рендер проверяются тем же испытательным циклом.
		if view._surface.register_geological_scar(
				kind, position, entry["radius"], 1.0):
			view._refresh_visible(true)
		var sync_ms := float(Time.get_ticks_usec() - start) / 1000.0

		# Измеряем именно кадровый интервал, пока игровая очередь
		# перестраивает видимые меши и коллизии. Ограничиваем
		# ожидание 30 секундами: на быстром CPU 240 кадров проходят
		# раньше, чем два фоновых потока закончат строить геометрию.
		var frames: Array[float] = []
		var peak_pending := 0
		var timed_out := true
		var last_tick := Time.get_ticks_usec()
		for frame in range(1800):
			await view.get_tree().process_frame
			var tick := Time.get_ticks_usec()
			frames.append(float(tick - last_tick) / 1000.0)
			last_tick = tick
			var pending: int = view._pending.size() + view._chunk_jobs.size() \
				+ view._rebuild_pending.size() + view._nature_dirty.size()
			peak_pending = maxi(peak_pending, pending)
			if float(tick - start) / 1000.0 > 30000.0:
				break
			# Дожидаемся четырёх игровых кадров после воздействия
			# и полного опустошения очередей. Размер wanted может
			# включать отсечённые камерой чанки, поэтому не сравниваем
			# его с числом созданных мешей: это давало ложный тайм-аут.
			if pending == 0 and frame >= 3:
				timed_out = false
				break
		results.append({
			"kind": kind, "applied": true,
			"vertices": int(changed.get("vertices", 0)),
			"world_revision": view._world_model.revision,
			"trees_felled": int(impact.get("trees_felled", 0)),
			"sync_cpu_ms": sync_ms,
			"frame_interval_p50_ms": Metrics.percentile(frames, 0.50),
			"frame_interval_p95_ms": Metrics.percentile(frames, 0.95),
			"frame_interval_p99_ms": Metrics.percentile(frames, 0.99),
			"frames_observed": frames.size(),
			"peak_pending_chunks": peak_pending,
			"queue_timeout": timed_out,
			"remaining_pending": view._pending.size(),
			"remaining_jobs": view._chunk_jobs.size(),
			"remaining_rebuilds": view._rebuild_pending.size(),
			"remaining_nature": view._nature_dirty.size()
		})
	# Результат содержит только измерения реального запущенного
	# Godot. Не выдаём интервалы CPU за время GPU или VRAM.
	var dimensions: Vector2 = view.get_viewport().get_visible_rect().size
	return {
		"schema_version": 1, "stage": "11.7/RF4",
		"route": "ландшафтные_воздействия_3",
		"platform": OS.get_name(),
		"engine": Engine.get_version_info().get("string", "unknown"),
		"render_backend": DisplayServer.get_name(),
		"headless": DisplayServer.get_name() == "headless",
		"viewport": {"width": int(dimensions.x), "height": int(dimensions.y)},
		"map": view._world_model.config.to_data(),
		"initial_revision": original_revision,
		"final_revision": view._world_model.revision,
		"units": {
			"sync_cpu_ms": "время физической синхронизации и постановки чанков, не GPU",
			"frame_interval_p95_ms": "95-й перцентиль интервала между кадрами",
			"queue_timeout": "очередь не завершилась за 30 секунд или 1800 кадров"
		},
		"events": results
	}


func run_relief(view: Node3D) -> Dictionary:
	# R6 использует существующий игровой маршрут 8.8, а не
	# собственную искусственную сцену. Оба прохода имеют один seed,
	# одинаковые 370 точек камеры и реальные чанки World.
	var material: ShaderMaterial = view._ground_material
	var original_rock: float = float(material.get_shader_parameter("rock_face_detail"))
	var original_palette: float = float(material.get_shader_parameter(
		"terrain_palette_strength"))
	var original_world: Dictionary = view._world_model.to_data()
	var original_surface: Dictionary = view._surface.to_snapshot()
	var original_hydro: Dictionary = view._hydro.to_snapshot()
	var passes: Array[Dictionary] = []

	for profile in [
		{"name": "исходный_материал", "rock": 0.0, "palette": 0.0},
		{"name": "материал_R4b", "rock": 1.0, "palette": 1.0}
	]:
		# Меняем только параметры исходного ShaderMaterial.
		# Внутренний run() сам сбрасывает очередь графических чанков
		# и повторяет тот же маршрут без изменения модели физики.
		material.set_shader_parameter("rock_face_detail", profile["rock"])
		material.set_shader_parameter(
			"terrain_palette_strength", profile["palette"])
		var measured: Dictionary = await run(view)
		passes.append({
			"name": profile["name"],
			"rock_face_detail": profile["rock"],
			"terrain_palette_strength": profile["palette"],
			"summary": measured["summary"],
			"phases": measured["phases"],
			"route_frames": measured["route_frames"]
		})

	# По окончании возвращаем пользовательские параметры материала.
	# Состояние мира проверяем отдельно от временных интервалов:
	# изменение красивости не должно менять грунты, воду или высоты.
	material.set_shader_parameter("rock_face_detail", original_rock)
	material.set_shader_parameter("terrain_palette_strength", original_palette)
	view._update_material_detail()
	var physics_unchanged: bool = (
		original_world == view._world_model.to_data()
		and original_surface == view._surface.to_snapshot()
		and original_hydro == view._hydro.to_snapshot()
	)
	var viewport_size: Vector2 = view.get_viewport().get_visible_rect().size
	return {
		"schema_version": 1,
		"stage": "relief/R6",
		"route": "camera-8.8-two-materials",
		"seed": view._world_model.config.world_seed,
		"map": view._world_model.config.to_data(),
		"platform": OS.get_name(),
		"engine": Engine.get_version_info().get("string", "unknown"),
		"display_server": DisplayServer.get_name(),
		"viewport": {"width": int(viewport_size.x),
			"height": int(viewport_size.y)},
		"physics_unchanged": physics_unchanged,
		"material_restored": (
			is_equal_approx(float(material.get_shader_parameter(
				"rock_face_detail")), original_rock)
			and is_equal_approx(float(material.get_shader_parameter(
				"terrain_palette_strength")), original_palette)
		),
		"passes": passes,
		"units": {
			"interval_ms": "настенный интервал кадров игрового цикла, не время GPU",
			"ground_prepare_worker_ms_total": "CPU подготовка сеток в потоках",
			"ground_upload_main_ms_total": "CPU создание ArrayMesh на главном потоке",
			"peak_godot_static_bytes": "статическая память Godot, не VRAM",
			"gpu_frame_ms": "не измеряется этим инструментом",
			"vram_bytes": "не измеряется этим инструментом"
		},
		"gpu_frame_ms": null,
		"vram_bytes": null,
		"artistic_approval": false,
		"hardware_approval": false
	}


func run_pbr_cache(view: Node3D, cache_kind: String = "shore") -> Dictionary:
	# Замер 9.4.2 выполняет штатный маршрут из 370 кадров дважды.
	# A/B проверяет либо старую оптимизацию береговых чтений,
	# либо общий снимок физических клеток для цвета и материала.
	# Другой кеш всегда включён и не смешивает результаты двух тестов.
	var physical: bool = cache_kind == "physical"
	var original_setting: bool = view._pbr_physical_cells_enabled if physical \
		else view._pbr_shore_cache_enabled
	var snapshot_world: Dictionary = view._world_model.to_data()
	var snapshot_hydro: Dictionary = view._hydro.to_snapshot()
	var snapshot_surface: Dictionary = view._surface.to_snapshot()
	var passes: Array[Dictionary] = []
	for candidate in [
		{"name": "предыдущий_алгоритм", "enabled": false},
		{"name": "локальный_кеш", "enabled": true}
	]:
		# run() сбрасывает кеш рендер-чанков и просматривает
		# идентичные точки камеры. Отдельные величины CPU и
		# главного потока не выдаём за аппаратное время GPU.
		if physical:
			view._pbr_physical_cells_enabled = candidate["enabled"]
		else:
			view._pbr_shore_cache_enabled = candidate["enabled"]
		var measured: Dictionary = await run(view)
		passes.append({
			"name": candidate["name"],
			"cache_enabled": candidate["enabled"],
			"route_frames": measured["route_frames"],
			"summary": measured["summary"],
			"phases": measured["phases"]
		})

	# Исходная настройка восстанавливается даже для тестового
	# запуска без кеша. Физические снимки сравниваем целиком.
	if physical:
		view._pbr_physical_cells_enabled = original_setting
	else:
		view._pbr_shore_cache_enabled = original_setting
	var physics_unchanged: bool = snapshot_world == view._world_model.to_data() \
		and snapshot_hydro == view._hydro.to_snapshot() \
		and snapshot_surface == view._surface.to_snapshot()
	var viewport: Vector2 = view.get_viewport().get_visible_rect().size
	return {
		"schema_version": 1,
		"task": "9.4.2/PBR-physical-cells" if physical else "9.4.2/PBR-shore-cache",
		"route": "camera-8.8-370-frames-twice",
		"map": view._world_model.config.to_data(),
		"platform": OS.get_name(),
		"engine": Engine.get_version_info().get("string", "unknown"),
		"display_server": DisplayServer.get_name(),
		"viewport": {"width": int(viewport.x), "height": int(viewport.y)},
		"passes": passes,
		"physics_unchanged": physics_unchanged,
		"setting_restored": (view._pbr_physical_cells_enabled if physical
			else view._pbr_shore_cache_enabled) == original_setting,
		"gpu_frame_ms": null,
		"vram_bytes": null,
		"hardware_approval": false,
		"units": {
			"ground_prepare_worker_ms_total": "CPU подготовки PBR-мешей в воркерах",
			"interval_ms_p95": "интервал кадров программного GL, не аппаратный FPS",
			"peak_godot_static_bytes": "статическая память движка, не VRAM"
		}
	}
