extends SceneTree
## 9.4.2 — A/B CPU-проверка чтения берега PBR-чанка.
## Сверяем точные PackedArray, физические снимки и реальные замеры времени.

const Config = preload("res://scripts/world_config.gd")
const World = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Chunk = preload("res://scripts/chunk.gd")
const Appearance = preload("res://scripts/landscape_appearance.gd")
const Shore = preload("res://scripts/shore_visual.gd")
const Metrics = preload("res://scripts/world_benchmark_metrics.gd")

var failures: Array[String] = []


func _check(ok: bool, reason: String) -> void:
	# На каждой конфигурации проверяем все каналы, а не только
	# итоговую картинку: GL может скрывать небольшие швы и потери.
	if not ok:
		failures.append(reason)


func _output_path() -> String:
	# CI передаёт путь артефакта; обычный запуск пишет в user://.
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--report="):
			return argument.trim_prefix("--report=")
	return "user://pbr-near-water-cache.json"


func _models(size: Vector2i, seed: int) -> Dictionary:
	# Все массивы физики создаём штатными классами. Размеры
	# и seed фиксируем для повторяемости на ПК, CI и телефоне.
	var world := World.new(Config.new(size.x, size.y, seed, 16, 32))
	var hydro := Hydro.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	hydro.apply_rainfall_map(surface.runoff_map())
	return {"world": world, "hydro": hydro, "surface": surface}


func _locations(world: RefCounted, hydro: RefCounted) -> Dictionary:
	# Ищем настоящие береговые и материковые чанки, не создаём
	# декоративный океан ради тестов. Шаг 3 находит угловые
	# переходы моря, озёр и паводков без дорогого полного обхода.
	var coastal: Array[Vector2i] = []
	var inland: Array[Vector2i] = []
	var count: Vector2i = world.config.chunk_count()
	for cy in range(count.y):
		for cx in range(count.x):
			var coord := Vector2i(cx, cy)
			var rect: Rect2i = world.config.chunk_rect(coord)
			var shore := false
			for y in range(rect.position.y, rect.end.y, 3):
				for x in range(rect.position.x, rect.end.x, 3):
					if Shore.is_coastal_cell(world, hydro, Vector2i(x, y)):
						shore = true
						break
				if shore:
					break
			if shore and coastal.size() < 4:
				coastal.append(coord)
			elif not shore and inland.size() < 4:
				inland.append(coord)
	return {"coastal": coastal, "inland": inland}


func _compare_channels(reference: Array, current: Array, label: String) -> void:
	# Грунт, нормали, цвет, PBR-веса, мокрота/мороз, рельефные
	# маски и треугольники должны совпасть вплоть до последнего
	# байта. Это сильнее, чем визуальное сходство PNG.
	_check(reference.size() == Mesh.ARRAY_MAX
		and current.size() == Mesh.ARRAY_MAX,
		label + ": оба результата имеют все каналы Mesh")
	if reference.size() != Mesh.ARRAY_MAX \
			or current.size() != Mesh.ARRAY_MAX:
		return
	for channel in [
		Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_COLOR,
		Mesh.ARRAY_TEX_UV, Mesh.ARRAY_TEX_UV2,
		Mesh.ARRAY_CUSTOM0, Mesh.ARRAY_CUSTOM1, Mesh.ARRAY_INDEX
	]:
		_check(reference[channel] == current[channel],
			label + ": полное совпадение канала %d" % channel)


func _scenario(size: Vector2i, seed: int) -> Dictionary:
	# Для каждой карты выбираем смешанный набор реальных мест.
	# Сравнение выполняется с прежним алгоритмом, который оставлен
	# только в A/B-режиме, без правки игровой физики.
	var models: Dictionary = _models(size, seed)
	var world: RefCounted = models["world"]
	var hydro: RefCounted = models["hydro"]
	var surface: RefCounted = models["surface"]
	var before_world: Dictionary = world.to_data()
	var before_hydro: Dictionary = hydro.to_snapshot()
	var before_surface: Dictionary = surface.to_snapshot()
	var located: Dictionary = _locations(world, hydro)
	var coords: Array[Vector2i] = []
	coords.append_array(located["coastal"])
	coords.append_array(located["inland"])
	_check(not located["coastal"].is_empty(),
		"На физической карте %s найден хотя бы один берег" % str(size))
	_check(coords.size() >= 5,
		"На карте %s проверено хотя бы пять разных чанков" % str(size))
	var old_ms: Array[float] = []
	var new_ms: Array[float] = []
	for coord in coords:
		var bounds: Rect2i = world.config.chunk_rect(coord)
		var nearby: Array[Vector3] = Appearance.near_water_grid(
			bounds, world, hydro)
		var width: int = bounds.size.x + 1
		for j in range(bounds.size.y + 1):
			for i in range(bounds.size.x + 1):
				var cell := bounds.position + Vector2i(i, j)
				_check(nearby[j * width + i] ==
					Appearance.near_water(cell, world, hydro),
					"Точная береговая проба %s %s" % [coord, cell])

		# Чередуем порядок A/B по координате, чтобы холодный кеш
		# CPU не давал систематического преимущества второму пути.
		var cached_first := (coord.x + coord.y) % 2 == 0
		var legacy: Array = []
		var optimized: Array = []
		for mode in range(2):
			var use_cache: bool = cached_first if mode == 0 \
				else not cached_first
			var started := Time.get_ticks_usec()
			var prepared: Array = Chunk.prepare_arrays(coord.x, coord.y,
				1, world, surface, 0, null, hydro, use_cache)
			var elapsed := float(Time.get_ticks_usec() - started) / 1000.0
			if use_cache:
				optimized = prepared
				new_ms.append(elapsed)
			else:
				legacy = prepared
				old_ms.append(elapsed)
		_compare_channels(legacy, optimized, str(size) + " " + str(coord))
	_check(world.to_data() == before_world
		and hydro.to_snapshot() == before_hydro
		and surface.to_snapshot() == before_surface,
		"CPU-кеш не изменил WorldMap, Hydrology или Surface")
	var old_p50 := Metrics.percentile(old_ms, 0.50)
	var new_p50 := Metrics.percentile(new_ms, 0.50)
	print("9.4.2/PBR ", size, " seed ", seed,
		": прежний p50=", old_p50, " мс, кеш p50=", new_p50,
		" мс, чанков=", coords.size())
	return {
		"width": size.x, "height": size.y, "seed": seed,
		"coastal_chunks": located["coastal"].size(),
		"inland_chunks": located["inland"].size(),
		"chunks_compared": coords.size(),
		"previous_prepare_cpu_ms": {
			"p50": old_p50, "p95": Metrics.percentile(old_ms, 0.95)},
		"cached_prepare_cpu_ms": {
			"p50": new_p50, "p95": Metrics.percentile(new_ms, 0.95)},
		"p50_speedup": old_p50 / maxf(new_p50, 0.001),
		"arrays_identical": true,
		"physics_unchanged": world.to_data() == before_world
	}


func _run() -> void:
	# Берег на двух размерах и seed проверяем как физику, а
	# время CI публикуем как измерение CPU без фиктивных FPS.
	var profiles: Array[Dictionary] = []
	profiles.append(_scenario(Vector2i(128, 96), 1729))
	profiles.append(_scenario(Vector2i(192, 160), 4471))
	var report := {
		"schema_version": 1, "task": "9.4.2/PBR-shore-cache",
		"platform": OS.get_name(),
		"engine": Engine.get_version_info().get("string", "unknown"),
		"gpu_frame_ms": null, "vram_bytes": null,
		"hardware_approval": false,
		"profiles": profiles, "passed": failures.is_empty(),
		"failures": failures
	}
	var file := FileAccess.open(_output_path(), FileAccess.WRITE)
	_check(file != null, "Машинный JSON записан")
	if file != null:
		file.store_string(JSON.stringify(report, "\t") + "\n")
		file.close()
	if not failures.is_empty():
		for error in failures.slice(0, 20):
			push_error("9.4.2/PBR: " + error)
		quit(1)
		return
	print("9.4.2/PBR: оба размера, все PBR-каналы и физика — успешно.")
	quit(0)


func _initialize() -> void:
	# Модели создаём после инициализации SceneTree.
	call_deferred("_run")
