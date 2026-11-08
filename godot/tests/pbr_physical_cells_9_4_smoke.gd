extends SceneTree
## #93/PBR: один физический снимок для RGB и шести масок материала.
## Проверяем побайтовую точность, смену сезона, швы и CPU A/B.

const Config = preload("res://scripts/world_config.gd")
const World = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Chunk = preload("res://scripts/chunk.gd")
const Appearance = preload("res://scripts/landscape_appearance.gd")
const MaterialMix = preload("res://scripts/terrain_material_mix.gd")
const Physical = preload("res://scripts/terrain_pbr_cells.gd")
const Shore = preload("res://scripts/shore_visual.gd")
const Metrics = preload("res://scripts/world_benchmark_metrics.gd")

var errors: Array[String] = []


func _check(ok: bool, message: String) -> void:
	# Накапливаем сбои независимо по каналам, временам и физике:
	# совпадение картинки не скрывает разницу RGBA8 или стыка.
	if not ok:
		errors.append(message)


func _path() -> String:
	# Путь отчёта задаётся CI, ручной запуск пишет в user://.
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--report="):
			return argument.trim_prefix("--report=")
	return "user://pbr-physical-cells.json"


func _models(size: Vector2i, seed: int) -> Dictionary:
	# Строим подлинный физический рельеф, почвы и сток;
	# никакой декоративной маски ради прохождения теста.
	var world := World.new(Config.new(size.x, size.y, seed, 16, 32))
	var hydro := Hydro.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	hydro.apply_rainfall_map(surface.runoff_map())
	return {"world": world, "hydro": hydro, "surface": surface}


func _locations(world: RefCounted, hydro: RefCounted) -> Dictionary:
	# Берём как береговую, так и обычную сушу; первая клетка
	# мира проверяется отдельно как граница с отсутствующими соседями.
	var coastal: Array[Vector2i] = []
	var inland: Array[Vector2i] = []
	var count: Vector2i = world.config.chunk_count()
	for cy in range(count.y):
		for cx in range(count.x):
			var chunk := Vector2i(cx, cy)
			var rect: Rect2i = world.config.chunk_rect(chunk)
			var has_shore := false
			for y in range(rect.position.y, rect.end.y, 3):
				for x in range(rect.position.x, rect.end.x, 3):
					if Shore.is_coastal_cell(world, hydro, Vector2i(x, y)):
						has_shore = true
						break
				if has_shore:
					break
			if has_shore and coastal.size() < 4:
				coastal.append(chunk)
			elif not has_shore and inland.size() < 4:
				inland.append(chunk)
	return {"coastal": coastal, "inland": inland}


func _arrays_equal(old: Array, current: Array, tag: String) -> void:
	# Сравниваем не только цвет, но PBR UV/UV2, снег в alpha,
	# влажность/лед в CUSTOM0, рельеф, треугольники и нормали.
	_check(old.size() == Mesh.ARRAY_MAX and current.size() == Mesh.ARRAY_MAX,
		tag + ": оба меша имеют все каналы")
	if old.size() != Mesh.ARRAY_MAX or current.size() != Mesh.ARRAY_MAX:
		return
	for channel in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_COLOR,
			Mesh.ARRAY_TEX_UV, Mesh.ARRAY_TEX_UV2, Mesh.ARRAY_CUSTOM0,
			Mesh.ARRAY_CUSTOM1, Mesh.ARRAY_INDEX]:
		_check(old[channel] == current[channel],
			tag + ": совпадает канал %d" % channel)


func _scenario(size: Vector2i, seed: int) -> Dictionary:
	# Период жизни физического кеша — одно построение одного чанка.
	# Порядок A/B чередуем, чтобы прогрев CPU не смещал измерение.
	var state := _models(size, seed)
	var world: RefCounted = state["world"]
	var hydro: RefCounted = state["hydro"]
	var surface: RefCounted = state["surface"]
	var before_world: Dictionary = world.to_data()
	var before_hydro: Dictionary = hydro.to_snapshot()
	var before_surface: Dictionary = surface.to_snapshot()
	var places: Dictionary = _locations(world, hydro)
	var chosen: Array[Vector2i] = []
	chosen.append_array(places["coastal"])
	chosen.append_array(places["inland"])
	_check(places["coastal"].size() > 0 and chosen.size() >= 5,
		"Есть реальный берег и не меньше пяти чанков %s" % str(size))
	var old_ms: Array[float] = []
	var new_ms: Array[float] = []
	for coord in chosen:
		var rect: Rect2i = world.config.chunk_rect(coord)
		var physical: Array[Dictionary] = Physical.grid(rect, world, surface, hydro)
		_check(physical.size() == (rect.size.x + 2) * (rect.size.y + 2),
			"Полная физическая рамка для " + str(coord))
		var vertex := rect.position + Vector2i(4, 4)
		var cells: Array[Dictionary] = Physical.vertex_cells(rect, vertex, physical)
		var h: float = world.vertex_at(vertex)
		var normal: Vector3 = world.normal_at(vertex)
		var shore: Vector3 = Appearance.near_water(vertex, world, hydro)
		_check(cells.size() == 4, "Четыре действительные соседние клетки")
		_check(Appearance.color_at(vertex, h, normal, world, surface, hydro, shore)
			== Appearance.color_at(vertex, h, normal, world, surface, hydro,
				shore, cells), "Цвет вершины совпадает с независимым эталоном")
		_check(MaterialMix.sample_at(vertex, h, normal, world, surface, hydro, shore)
			== MaterialMix.sample_at(vertex, h, normal, world, surface, hydro,
				shore, cells), "Шесть PBR-масок и условия совпадают")
		var old: Array = []
		var current: Array = []
		var optimized_first := (coord.x + coord.y) % 2 == 0
		for attempt in range(2):
			var optimized: bool = optimized_first if attempt == 0 else not optimized_first
			var started: int = Time.get_ticks_usec()
			var arrays: Array = Chunk.prepare_arrays(coord.x, coord.y, 1,
				world, surface, 0, null, hydro, true, Callable(), optimized)
			var elapsed: float = float(Time.get_ticks_usec() - started) / 1000.0
			if optimized:
				current = arrays
				new_ms.append(elapsed)
			else:
				old = arrays
				old_ms.append(elapsed)
		_arrays_equal(old, current, str(size) + " " + str(coord))
	_check(world.to_data() == before_world and hydro.to_snapshot() == before_hydro
		and surface.to_snapshot() == before_surface,
		"Кеш не изменил физику мира, воды и грунта")
	var previous_p50: float = Metrics.percentile(old_ms, 0.5)
	var cached_p50: float = Metrics.percentile(new_ms, 0.5)
	print("#93/PBR-CELLS ", size, ": до ", previous_p50,
		" мс, после ", cached_p50, " мс, чанков ", chosen.size())
	return {
		"width": size.x, "height": size.y, "seed": seed,
		"coastal_chunks": places["coastal"].size(),
		"inland_chunks": places["inland"].size(),
		"chunks_compared": chosen.size(), "arrays_identical": true,
		"physics_unchanged": world.to_data() == before_world,
		"previous_prepare_cpu_ms": {"p50": previous_p50,
			"p95": Metrics.percentile(old_ms, 0.95)},
		"shared_prepare_cpu_ms": {"p50": cached_p50,
			"p95": Metrics.percentile(new_ms, 0.95)},
		"p50_speedup": previous_p50 / maxf(0.001, cached_p50)
	}


func _seasonal() -> void:
	# Зиму и дождь переключаем на настоящих физических полях.
	# После восстановления исходного состояния точный снимок
	# повторно не используется: ревизии не переживают вызов.
	var state := _models(Vector2i(64, 48), 1729)
	var world: RefCounted = state["world"]
	var hydro: RefCounted = state["hydro"]
	var surface: RefCounted = state["surface"]
	var point := Vector2i(-1, -1)
	for y in range(2, 46):
		for x in range(2, 62):
			var cell := Vector2i(x, y)
			var dry := true
			for dy in [-1, 0]:
				for dx in [-1, 0]:
					if hydro.has_water(hydro.cell_index(cell + Vector2i(dx, dy))):
						dry = false
			if dry:
				point = cell
				break
		if point.x >= 0:
			break
	_check(point.x >= 0, "Для дождя и зимы найдена настоящая суша")
	if point.x < 0:
		return
	var original := {}
	for dy in [-1, 0]:
		for dx in [-1, 0]:
			var i: int = hydro.cell_index(point + Vector2i(dx, dy))
			original[i] = Vector4(surface._moisture[i], surface._frost[i],
				surface._snow[i], surface._waterlogged[i])
			surface._moisture[i] = 1.0
			surface._frost[i] = 1.0
			surface._snow[i] = 1.0
			surface._waterlogged[i] = 0.8
	var coord := world.config.chunk_of(point)
	var old: Array = Chunk.prepare_arrays(coord.x, coord.y, 1,
		world, surface, 0, null, hydro, true, Callable(), false)
	var current: Array = Chunk.prepare_arrays(coord.x, coord.y, 1,
		world, surface, 0, null, hydro, true, Callable(), true)
	_arrays_equal(old, current, "Реальный дождь, мокрая почва, снег и мороз")
	for i in original:
		var saved: Vector4 = original[i]
		surface._moisture[i] = saved.x
		surface._frost[i] = saved.y
		surface._snow[i] = saved.z
		surface._waterlogged[i] = saved.w


func _seam() -> void:
	# Отдельно сопоставляем общую вертикальную границу двух чанков.
	# Не допускаем шва даже после изменения порядка CPU-проб.
	var state := _models(Vector2i(64, 48), 4471)
	var world: RefCounted = state["world"]
	var hydro: RefCounted = state["hydro"]
	var surface: RefCounted = state["surface"]
	var left: Array = Chunk.prepare_arrays(1, 1, 1, world, surface, 0, null, hydro)
	var right: Array = Chunk.prepare_arrays(2, 1, 1, world, surface, 0, null, hydro)
	var stride := 17
	for row in range(stride):
		var li := row * stride + 16
		var ri := row * stride
		for channel in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_COLOR,
				Mesh.ARRAY_TEX_UV, Mesh.ARRAY_TEX_UV2]:
			_check(left[channel][li] == right[channel][ri],
				"Бесшовный канал %d, вершина %d" % [channel, row])
		for extra in [Mesh.ARRAY_CUSTOM0, Mesh.ARRAY_CUSTOM1]:
			for byte in range(4):
				_check(left[extra][li * 4 + byte] == right[extra][ri * 4 + byte],
					"Бесшовная маска %d, вершина %d" % [extra, row])


func _run() -> void:
	# Выводим два независимых размера/seed и сезонные/стыковые тесты.
	# Никакие программные CPU-метрики не называем FPS на GTX/Android.
	var profiles: Array[Dictionary] = [
		_scenario(Vector2i(128, 96), 1729),
		_scenario(Vector2i(192, 160), 4471)
	]
	_seasonal()
	_seam()
	var report := {
		"task": "#93/PBR-physical-cells", "schema_version": 1,
		"engine": Engine.get_version_info().get("string", "unknown"),
		"platform": OS.get_name(), "hardware_approval": false,
		"gpu_frame_ms": null, "vram_bytes": null,
		"profiles": profiles, "passed": errors.is_empty(), "errors": errors
	}
	var file := FileAccess.open(_path(), FileAccess.WRITE)
	_check(file != null, "JSON сохранён")
	if file != null:
		file.store_string(JSON.stringify(report, "\t") + "\n")
		file.close()
	if not errors.is_empty():
		for reason in errors.slice(0, 30):
			push_error("#93/PBR-CELLS: " + reason)
		quit(1)
		return
	print("#93/PBR-CELLS: два seed, сезон, шов, маски и CPU — успешно")
	quit(0)


func _initialize() -> void:
	# Инициализацию физических моделей выполняем после SceneTree.
	call_deferred("_run")
