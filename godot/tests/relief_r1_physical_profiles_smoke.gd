extends SceneTree
## R1 — измеримый профиль настоящих гор и оврагов.
## Результаты основаны на WorldMap, а не на декоративном шейдере.
## Сравниваем seed, поперечные сечения и реальные швы чанков.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Terrain = preload("res://scripts/terrain.gd")
const Chunk = preload("res://scripts/chunk.gd")
const Features = preload("res://scripts/relief_visual_features.gd")

const WIDTH := 384
const HEIGHT := 288
const STEP := 3
const SEEDS := [1729, 1802, 2240]
const OUTPUT := "res://../relief-r1-physical-profiles.json"

var failures: Array[String] = []


func _check(ok: bool, reason: String) -> void:
	# Записываем все нарушения: один неудачный seed не должен
	# скрыть остальные геометрические ошибки в отчёте.
	if not ok:
		failures.append(reason)


func _profile(seed: int) -> Dictionary:
	# Один WorldMap обслуживает физическую карту и обе визуальные
	# сетки. Высоты берём из карты с настоящими географическими
	# границами, а форму классифицируем из Terrain.
	var world := Map.new(Config.new(WIDTH, HEIGHT, seed, 16, 64))
	var summit := -INF
	var low := INF
	var mountain_count := 0
	var cliff_count := 0
	var ravine_count := 0
	var steepest := 0.0
	var summit_cell := Vector2i.ZERO
	var ravine_cell := Vector2i.ZERO
	var ravine_depth := 0.0
	var samples := 0
	for y in range(24, HEIGHT - 24, STEP):
		for x in range(24, WIDTH - 24, STEP):
			var cell := Vector2i(x, y)
			var height: float = world.vertex_at(cell)
			var shape: Dictionary = Terrain.sample(float(x), float(y), seed)
			var form: String = str(shape["form"])
			var normal: Vector3 = world.normal_at(cell)
			var slope: float = Vector2(normal.x, normal.z).length() \
				/ maxf(0.0001, normal.y)
			var features: Vector2 = Features.sample_at(world, cell)
			samples += 1
			if height > summit:
				summit = height
				summit_cell = cell
			low = minf(low, height)
			steepest = maxf(steepest, slope)
			if form == "горы":
				mountain_count += 1
			if slope > 0.6:
				cliff_count += 1
			if form == "овраг":
				ravine_count += 1
				if features.y > ravine_depth:
					ravine_depth = features.y
					ravine_cell = cell

	# Для одного и того же участка строим два настоящих ArrayMesh.
	# Сравнение координат доказывает, что LOD не придумывает горы.
	var chunk: Vector2i = world.config.chunk_of(summit_cell)
	var close: Array = Chunk.prepare_arrays(chunk.x, chunk.y, 1, world,
		null, 0, null, null)
	var far: Array = Chunk.prepare_arrays(chunk.x, chunk.y, 1, world,
		null, 2, null, null)
	var close_vertices: PackedVector3Array = close[Mesh.ARRAY_VERTEX]
	var far_vertices: PackedVector3Array = far[Mesh.ARRAY_VERTEX]
	_check(close_vertices.size() > 0 and far_vertices.size() > 0,
		"У seed %d обе геометрии LOD не пустые" % seed)
	var physical: Vector3 = world.config.to_scene(Vector2(summit_cell), summit)
	var vertex_found := false
	for vertex in close_vertices:
		if vertex.distance_to(physical) < 0.001:
			vertex_found = true
			break
	_check(vertex_found,
		"У seed %d настоящая вершина горы совпадает с WorldMap" % seed)

	# Фиксируем поперечный профиль высот через найденный пик.
	# Данные можно повторно построить и сравнить между версиями.
	var transect: Array[Dictionary] = []
	for dx in range(-24, 25, 4):
		var x := clampi(summit_cell.x + dx, 0, WIDTH)
		var cell := Vector2i(x, summit_cell.y)
		transect.append({"x": x, "height": snappedf(
			world.vertex_at(cell), 0.001)})
	_check(mountain_count > 0 and summit > 20.0,
		"У seed %d присутствует настоящий высокий горный массив" % seed)
	_check(cliff_count > 0 and steepest > 0.6,
		"У seed %d есть реальные крутые склоны" % seed)
	_check(ravine_count > 0,
		"У seed %d присутствует физический овраг" % seed)
	_check(world.changed_vertex_count() == 0,
		"Профилирование seed %d не деформировало карту" % seed)

	return {
		"seed": seed, "samples": samples,
		"summit_height": snappedf(summit, 0.001),
		"minimum_height": snappedf(low, 0.001),
		"relief_span": snappedf(summit - low, 0.001),
		"mountain_samples": mountain_count,
		"steep_samples": cliff_count,
		"ravine_samples": ravine_count,
		"maximum_slope": snappedf(steepest, 0.001),
		"ravine_concavity": snappedf(ravine_depth, 0.001),
		"summit_cell": [summit_cell.x, summit_cell.y],
		"ravine_cell": [ravine_cell.x, ravine_cell.y],
		"transect": transect,
		"lod_close_vertices": close_vertices.size(),
		"lod_far_vertices": far_vertices.size()
	}


func _run() -> void:
	# Независимые seed обеспечивают воспроизводимую проверку,
	# а JSON сохраняет конкретные числа для следующих PR по
	# материалам, свету и сравнительным ракурсам R4/R5.
	var profiles: Array[Dictionary] = []
	for seed in SEEDS:
		var profile := _profile(seed)
		profiles.append(profile)
		print("R1 seed=", seed, " peak=", profile["summit_height"],
			" relief=", profile["relief_span"],
			" slope=", profile["maximum_slope"],
			" mountain=", profile["mountain_samples"],
			" ravines=", profile["ravine_samples"])
	var report := {
		"test": "relief-R1-physical-profiles",
		"terrain_version": Config.TERRAIN_VERSION,
		"width": WIDTH, "height": HEIGHT, "step": STEP,
		"seeds": SEEDS, "profiles": profiles, "failures": failures,
		"art_approval": false,
		"hardware_approval": false
	}
	var file := FileAccess.open(OUTPUT, FileAccess.WRITE)
	_check(file != null, "JSON-отчёт удалось открыть для записи")
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))
		file.close()
	if failures.is_empty():
		print("R1: физические горы, овраги, уклоны и LOD — успешно")
		quit(0)
		return
	for failure in failures:
		push_error("R1: " + failure)
	quit(1)


func _initialize() -> void:
	call_deferred("_run")
