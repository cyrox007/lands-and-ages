extends SceneTree
## R6/CPU — сравнение настоящих природных чанков на трёх размерах карты.
## Headless измеряет CPU и буферы сетки, не FPS видеокарты.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Chunk = preload("res://scripts/chunk.gd")
const Metrics = preload("res://scripts/world_benchmark_metrics.gd")

const SIZES := [
	Vector2i(128, 96), Vector2i(256, 192), Vector2i(512, 384)
]
const SEED := 1729
const MAP_CHUNK := 16
var failures: Array[String] = []


func _check(condition: bool, reason: String) -> void:
	# Записываем каждую ошибку в итоговый отчёт. Отдельные размеры
	# карты продолжают проверяться даже при ошибке одного чанка.
	if not condition:
		failures.append(reason)


func _output_path() -> String:
	# В CI передаётся /tmp; локально отчёт находится в user://.
	for value in OS.get_cmdline_user_args():
		if value.begins_with("--report="):
			return value.trim_prefix("--report=")
	return "user://relief-r6-cpu.json"


func _sample_chunks(config: RefCounted) -> Array[Vector2i]:
	# Пять физически существующих областей распределены по карте,
	# к каждой прибавляем два соседних чанка. Это проверяет
	# масштабирование без подмены физической сетки мокапом.
	var selected: Array[Vector2i] = []
	for factor in [
		Vector2(0.12, 0.16), Vector2(0.25, 0.78),
		Vector2(0.50, 0.50), Vector2(0.72, 0.28),
		Vector2(0.85, 0.84)
	]:
		var point := Vector2i(
			clampi(roundi(float(config.width) * factor.x), 0, config.width - 1),
			clampi(roundi(float(config.height) * factor.y), 0, config.height - 1))
		var base: Vector2i = config.chunk_of(point)
		for offset in [Vector2i.ZERO, Vector2i.RIGHT, Vector2i.DOWN]:
			var candidate: Vector2i = base + offset
			if config.chunk_rect(candidate).has_area() and not selected.has(candidate):
				selected.append(candidate)
	return selected


func _profile(size: Vector2i) -> Dictionary:
	# Используем те же WorldMap, Hydrology, Surface и Chunk, что
	# игровая сцена. Засекаем инициализацию отдельно от мешей,
	# поскольку сравнивать эти затраты как один GPU-вызов нельзя.
	var started := Time.get_ticks_usec()
	var world := Map.new(Config.new(size.x, size.y, SEED, MAP_CHUNK, 64))
	var hydro := Hydro.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	hydro.apply_rainfall_map(surface.runoff_map())
	var initialization_ms := float(Time.get_ticks_usec() - started) / 1000.0
	var before_world: Dictionary = world.to_data()
	var before_surface: Dictionary = surface.to_snapshot()
	var before_hydro: Dictionary = hydro.to_snapshot()

	# Создаём реальные массивы PBR-геометрии в разных областях:
	# вода и материалы рассчитываются из физической модели,
	# поэтому результаты сопоставимы с CPU-частью игрового рендера.
	var durations: Array[float] = []
	var vertices_total := 0
	var triangles_total := 0
	var estimated_bytes := 0
	var sampled: Array[Vector2i] = _sample_chunks(world.config)
	for coord in sampled:
		var before := Time.get_ticks_usec()
		var arrays: Array = Chunk.prepare_arrays(coord.x, coord.y, 1,
			world, surface, 0, null, hydro)
		durations.append(float(Time.get_ticks_usec() - before) / 1000.0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var bounds: Rect2i = world.config.chunk_rect(coord)
		var expected := world.config.to_scene(
			Vector2(bounds.position), world.vertex_at(bounds.position))
		_check(not vertices.is_empty() and not indices.is_empty(),
			"R6 %s: реальный PBR-меш не пуст" % str(size))
		if not vertices.is_empty():
			_check(vertices[0].distance_to(expected) < 0.001,
				"R6 %s: позиция меша совпадает с WorldMap" % str(size))
		vertices_total += vertices.size()
		triangles_total += int(indices.size() / 3)
		# Только грубая оценка байт CPU-массивов, а не GPU/VRAM:
		# позиция+нормаль+цвет+два UV+два RGBA8 и индексы.
		estimated_bytes += vertices.size() * (12 + 12 + 16 + 8 + 8 + 8)
		estimated_bytes += indices.size() * 4

	# Чтение геометрии не имеет права менять физическую карту,
	# наносы или структуру стока. Проверяем снимки каждого слоя.
	var unchanged := before_world == world.to_data() \
		and before_surface == surface.to_snapshot() \
		and before_hydro == hydro.to_snapshot()
	_check(unchanged, "R6 %s: состояние физики не изменилось" % str(size))
	_check(durations.size() >= 10,
		"R6 %s: измерены не менее десяти чанков" % str(size))
	_check(vertices_total > 0 and triangles_total > 0,
		"R6 %s: сетки содержат настоящие треугольники" % str(size))
	var p50 := Metrics.percentile(durations, 0.50)
	var p95 := Metrics.percentile(durations, 0.95)
	var p99 := Metrics.percentile(durations, 0.99)
	print("R6/CPU ", size, ": чанков=", sampled.size(),
		" p50=", p50, " p95=", p95, " p99=", p99, " мс")
	return {
		"width": size.x, "height": size.y, "seed": SEED,
		"cells": size.x * size.y,
		"sampled_chunks": sampled.size(),
		"initialization_cpu_ms": initialization_ms,
		"mesh_prepare_ms": {"p50": p50, "p95": p95, "p99": p99,
			"max": Metrics.percentile(durations, 1.0)},
		"vertices_total": vertices_total,
		"triangles_total": triangles_total,
		"estimated_cpu_array_bytes": estimated_bytes,
		"physics_unchanged": unchanged
	}


func _run() -> void:
	# Все конфигурации используют один seed и одну версию рельефа.
	# Проверка не вводит пороги FPS: GitHub Runner не является
	# эталонным ПК пользователя и тем более смартфоном.
	var profiles: Array[Dictionary] = []
	for size in SIZES:
		profiles.append(_profile(size))
	var report := {
		"schema_version": 1, "stage": "relief/R6-CPU",
		"terrain_version": Config.TERRAIN_VERSION,
		"engine": Engine.get_version_info().get("string", "unknown"),
		"platform": OS.get_name(),
		"headless": DisplayServer.get_name() == "headless",
		"hardware_approval": false,
		"gpu_frame_ms": null, "vram_bytes": null,
		"profiles": profiles,
		"passed": failures.is_empty(), "failures": failures
	}
	var file := FileAccess.open(_output_path(), FileAccess.WRITE)
	_check(file != null, "R6: JSON-отчёт записан")
	if file != null:
		file.store_string(JSON.stringify(report, "\t") + "\n")
		file.close()
	if not failures.is_empty():
		for reason in failures:
			push_error(reason)
		quit(1)
		return
	print("R6/CPU: три размера, физические меши, p50/p95/p99 — успешно.")
	quit(0)


func _initialize() -> void:
	# Создание SceneTree откладываем до следующего кадра, чтобы
	# Godot успел подготовить собственные счётчики времени.
	call_deferred("_run")
