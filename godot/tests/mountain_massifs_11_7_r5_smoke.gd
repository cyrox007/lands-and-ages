extends SceneTree
## R5 — физические высокие хребты, настоящая гидрология и WorldSave.
## Это проверки геометрии Godot, а не художественная приёмка
## или замеры аппаратного GPU на телефоне.

const Config = preload("res://scripts/world_config.gd")
const Terrain = preload("res://scripts/terrain.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const Weather = preload("res://scripts/weather_events.gd")
const Processes = preload("res://scripts/natural_processes.gd")
const Disasters = preload("res://scripts/natural_disasters.gd")
const Fire = preload("res://scripts/fire_registry.gd")
const Save = preload("res://scripts/world_save.gd")
const Chunk = preload("res://scripts/chunk.gd")
const Landscape = preload("res://scripts/landscape_events.gd")

const SEEDS := [1729, 4471, 8429]
const SIZE := Vector2i(256, 192)
const OUTPUT := "res://tests/mountain-r5-report.json"
var failures: Array[String] = []
var results: Array[Dictionary] = []


func _check(ok: bool, message: String) -> void:
	# Сохраняем причины отклонений по всем seed: новая физика
	# должна быть детерминированной, а не зависеть от одного кадра.
	if not ok and failures.size() < 45:
		failures.append(message)


func _mountain_anchor(seed: int) -> Vector2:
	# Вычисляем настоящее положение семенного горного массива
	# из того же FEATURE_STEP и jitter, что использует Terrain.
	# Не подставляем заранее найденную координату одного seed.
	var chosen := Vector2(-1.0, -1.0)
	for gy in range(-1, 4):
		for gx in range(-1, 5):
			if Terrain._form_index(gx, gy, seed) != 4:
				continue
			var jitter_x: float = (Terrain.hash2(gx, gy, seed + 11) - 0.5) * 0.32
			var jitter_y: float = (Terrain.hash2(gx, gy, seed + 12) - 0.5) * 0.32
			var point := Vector2(
				(float(gx) + 0.5 + jitter_x) * Terrain.FEATURE_STEP,
				(float(gy) + 0.5 + jitter_y) * Terrain.FEATURE_STEP)
			if point.x < 26.0 or point.y < 26.0 \
					or point.x > float(SIZE.x) - 26.0 \
					or point.y > float(SIZE.y) - 26.0:
				continue
			if chosen.x < 0.0 or point.distance_squared_to(
					Vector2(SIZE) * 0.5) < chosen.distance_squared_to(
					Vector2(SIZE) * 0.5):
				chosen = point
	return chosen


func _validate_shape(world: RefCounted, seed: int) -> Dictionary:
	# Находим настоящую вершину непосредственно в WorldMap:
	# максимумы не рисуются отдельной декорацией в шейдере.
	var center: Vector2 = _mountain_anchor(seed)
	_check(center.x >= 0.0, "Для seed %d создан горный массив" % seed)
	if center.x < 0.0:
		return {}
	var best_height := -INF
	var peak := Vector2i.ZERO
	var steepest := 0.0
	for y in range(maxi(0, roundi(center.y) - 19),
			mini(SIZE.y, roundi(center.y) + 19), 2):
		for x in range(maxi(0, roundi(center.x) - 19),
				mini(SIZE.x, roundi(center.x) + 19), 2):
			var vertex := Vector2i(x, y)
			var height: float = world.vertex_at(vertex)
			if height > best_height:
				best_height = height
				peak = vertex
			var neighbour: float = world.vertex_at(vertex + Vector2i(1, 0))
			steepest = maxf(steepest, absf(neighbour - height))

	# Сверяем обрыв с физическими предгорьями поперёк оси:
	# максимальная высота сама по себе не доказывает наличие гор.
	var gx := floori(center.x / Terrain.FEATURE_STEP)
	var gy := floori(center.y / Terrain.FEATURE_STEP)
	var angle: float = Terrain.hash2(gx, gy, seed + 13) * TAU
	var along := Vector2(cos(angle), sin(angle))
	var across := Vector2(-sin(angle), cos(angle))
	var shoulder_a: float = world.height_at(center + across * 21.0)
	var shoulder_b: float = world.height_at(center - across * 21.0)
	var prominence := best_height - maxf(shoulder_a, shoulder_b)
	var ridge_a: float = world.height_at(center + along * 10.0)
	var ridge_b: float = world.height_at(center - along * 10.0)
	_check(best_height >= 18.0,
		"Seed %d: высокая вершина вместо девятиединичного холма" % seed)
	_check(prominence >= 11.5,
		"Seed %d: вершина выше обоих предгорий на 11.5+" % seed)
	_check(minf(ridge_a, ridge_b) >= 12.0,
		"Seed %d: протяжённый хребет с двумя плечами" % seed)
	_check(steepest >= 1.0 and steepest <= 9.0,
		"Seed %d: выраженные, но не вертикально разорванные склоны" % seed)

	# Рендер геометрии и соседние чанки используют общие
	# физические вершины даже на крутом гребне.
	var seam_x := clampi(ceili(float(peak.x) / 16.0) * 16,
		16, SIZE.x - 16)
	var cy := clampi(floori(float(peak.y) / 16.0), 0,
		floori(float(SIZE.y) / 16.0) - 1)
	var left: Array = Chunk.prepare_arrays(floori(float(seam_x) / 16.0) - 1,
		cy, 1, world)
	var right: Array = Chunk.prepare_arrays(floori(float(seam_x) / 16.0), cy, 1, world)
	var va: PackedVector3Array = left[Mesh.ARRAY_VERTEX]
	var vb: PackedVector3Array = right[Mesh.ARRAY_VERTEX]
	var row: int = clampi(peak.y - cy * 16, 0, 16)
	var y_left: float = va[row * 17 + 16].y
	var y_right: float = vb[row * 17].y
	var physics_y: float = world.vertex_at(Vector2i(seam_x, cy * 16 + row)) \
		* world.config.height_scale
	_check(absf(y_left - y_right) < 0.00001
		and absf(y_left - physics_y) < 0.00001,
		"Seed %d: стык двух ArrayMesh равен физическому WorldMap" % seed)

	# Повторяем физические вершины с тем же seed и без кэша.
	var second := Map.new(Config.new(SIZE.x, SIZE.y, seed, 16, 64))
	_check(second.vertex_at(peak) == best_height
		and second.vertex_at(Vector2i(seam_x, cy * 16 + row)) \
			== world.vertex_at(Vector2i(seam_x, cy * 16 + row)),
		"Seed %d: высокая геометрия детерминирована" % seed)
	return {
		"seed": seed, "peak_x": peak.x, "peak_y": peak.y,
		"maximum_height": best_height, "foothill_prominence": prominence,
		"ridge_side_a": ridge_a, "ridge_side_b": ridge_b,
		"steepest_step": steepest, "seam_verified": true
	}


func _physical_world(seed: int) -> Dictionary:
	# Создаём ту же цепочку, что игровая сцена: вода должна
	# течь по настоящим вершинам, снег лежать на поверхности,
	# а деревья иметь правильные физические координаты.
	var world := Map.new(Config.new(SIZE.x, SIZE.y, seed, 16, 64))
	var hydro := Hydro.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	var climate := Climate.new(world, hydro)
	climate.rebuild()
	_check(climate.set_day(1), "Климат инициализирован: %d" % seed)
	_check(surface.advance_climate_day(climate), "Почва инициализирована")
	hydro.apply_rainfall_map(surface.runoff_map())
	var nature := Nature.new(world, hydro, surface, climate)
	_check(nature.generate(), "Растительность построена на горах")
	return {
		"world": world, "hydro": hydro, "surface": surface,
		"climate": climate, "nature": nature,
		"weather": Weather.new(world, climate, surface, hydro),
		"natural": Processes.new(world, hydro, surface, climate),
		"disasters": Disasters.new(world, hydro, surface, climate),
		"fire": Fire.new(world, hydro, surface, climate, nature)
	}


func _hydrology_and_save(state: Dictionary, seed: int,
		summary: Dictionary) -> void:
	# Проверяем настоящий Priority-Flood и сохранение на
	# неизменённом горном ландшафте, а не на декоративной карте.
	var world: RefCounted = state["world"]
	var hydro: RefCounted = state["hydro"]
	_check(hydro.full_rebuilds > 0 and hydro.outlet_count() > 0,
		"Seed %d: водосбор и выходы рассчитаны" % seed)
	var snapshot: Dictionary = Save.capture(state)
	_check(not snapshot.is_empty(), "Seed %d: WorldSave создан" % seed)
	if snapshot.is_empty():
		return
	var loaded: Dictionary = Save.restore(
		JSON.parse_string(JSON.stringify(snapshot, "", true, true)))
	_check(not loaded.is_empty(), "Seed %d: WorldSave восстановлен" % seed)
	if loaded.is_empty():
		return
	_check(loaded["world"].to_data() == world.to_data()
		and loaded["hydro"].to_snapshot() == hydro.to_snapshot(),
		"Seed %d: физические высоты и водосбор неизменны" % seed)

	# Геологическая просадка меняет именно WorldMap. После неё
	# гидрология пересчитывается по тем же новым высотам, и
	# отложенное состояние вновь сериализуется без потери данных.
	var peak := Vector2(float(summary["peak_x"]) + 0.5,
		float(summary["peak_y"]) + 0.5)
	var impact: Dictionary = Landscape.new(world).apply(
		"просадка", peak, 5.0, 0.22)
	_check(not impact.is_empty(), "Seed %d: геология меняет горный склон" % seed)
	if impact.is_empty():
		return
	hydro.rebuild()
	state["surface"].rebuild()
	_check(hydro.full_rebuilds > 1 and world.changed_vertex_count() > 0,
		"Seed %d: изменены физические вершины и пересчитана вода" % seed)
	var after: Dictionary = Save.capture(state)
	_check(not after.is_empty(), "Seed %d: мир после деформации сохраняется" % seed)
	if after.is_empty():
		return
	var restored: Dictionary = Save.restore(
		JSON.parse_string(JSON.stringify(after, "", true, true)))
	_check(not restored.is_empty(), "Seed %d: мир после деформации восстановлен" % seed)
	if not restored.is_empty():
		_check(restored["world"].to_data() == world.to_data(),
			"Seed %d: изменённые вершины не потерялись" % seed)
	summary["changed_vertices"] = world.changed_vertex_count()
	summary["outlets"] = hydro.outlet_count()


func _run() -> void:
	# Один программный CI покрывает три детерминированные карты.
	# Подмена генератора не может случайно пройти из-за рисунка.
	var legacy := Config.new().to_data()
	legacy.erase("terrain_version")
	_check(Config.from_data(legacy) == null,
		"Старые сейвы с неподтверждённым рельефом отклоняются")
	legacy["terrain_version"] = Config.TERRAIN_VERSION
	_check(Config.from_data(legacy) != null,
		"Новый формат WorldConfig проходит строгую загрузку")
	for seed in SEEDS:
		var state: Dictionary = _physical_world(seed)
		var summary: Dictionary = _validate_shape(state["world"], seed)
		if summary.is_empty():
			continue
		_hydrology_and_save(state, seed, summary)
		results.append(summary)

	var report := {
		"schema_version": 1, "stage": "11.7/R5",
		"generator_version": Config.TERRAIN_VERSION,
		"hardware_fps_verified": false, "artistic_approval": false,
		"seeds": SEEDS, "scenarios": results,
		"passed": failures.is_empty() and results.size() == SEEDS.size(),
		"failures": failures
	}
	var file := FileAccess.open(OUTPUT, FileAccess.WRITE)
	_check(file != null, "Машинный отчёт гор создан")
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()
	if not failures.is_empty():
		for failure in failures:
			push_error("R5: " + failure)
		quit(1)
		return
	print("11.7/R5: физические массивы гор, гидрология, чанки, WorldSave — успешно.")
	quit(0)


func _initialize() -> void:
	call_deferred("_run")
