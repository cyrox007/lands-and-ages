extends SceneTree
## F5b2e2 — осаждение конечной речной золы и цвет действительной воды.
## Проверяем реальную гидрологию, PBR-меш, суточный расчёт и JSON v7.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const Fire = preload("res://scripts/fire_registry.gd")
const Water = preload("res://scripts/water_mesh.gd")
const Weather = preload("res://scripts/weather_events.gd")
const Processes = preload("res://scripts/natural_processes.gd")
const Disasters = preload("res://scripts/natural_disasters.gd")
const Save = preload("res://scripts/world_save.gd")
const WaterShader = preload("res://shaders/natural_water.gdshader")

var failures: Array[String] = []


func _check(ok: bool, reason: String) -> void:
	# Сохраняем все нарушения в одном запуске, чтобы различать
	# ошибку переноса массы, цвета меша и формата сохранения.
	if not ok:
		failures.append(reason)


func _models() -> Dictionary:
	# Создаём действительный водосбор и растительность. Геометрия,
	# климат, вода и пожарный реестр принадлежат той же архитектуре,
	# что используется игровым WorldDayRunner.
	var world := Map.new(Config.new(192, 160, 1729, 16, 32))
	var hydro := Hydro.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	var climate := Climate.new(world, hydro)
	climate.rebuild()
	_check(climate.set_day(1), "Первый день климата создан")
	_check(surface.advance_climate_day(climate), "Поверхность создана")
	hydro.apply_rainfall_map(surface.runoff_map())
	var nature := Nature.new(world, hydro, surface, climate)
	_check(nature.generate(), "Растительность готова")
	return {
		"world": world, "hydro": hydro, "surface": surface,
		"climate": climate, "nature": nature,
		"fire": Fire.new(world, hydro, surface, climate, nature)
	}


func _find_cell(world: RefCounted, hydro: RefCounted, water: bool) -> Vector2i:
	# Ищем физическую морскую или сухую клетку, а не назначаем
	# точку вручную. Это сохраняет повторяемость для фиксированного seed.
	for y in range(2, world.config.height - 2):
		for x in range(2, world.config.width - 2):
			var cell := Vector2i(x, y)
			var index: int = hydro.cell_index(cell)
			if water and hydro.ocean_at(index):
				return cell
			if not water and not hydro.has_water(index) \
					and not hydro.flooded_at(index):
				return cell
	_check(false, "Не найдено море или сухая земля на настоящей карте")
	return Vector2i(-1, -1)


func _advance(models: Dictionary, day: int) -> void:
	# Обновляем календарные зависимости до пожарного шага, как
	# делает основной WorldDayRunner. Визуальный меш не влияет на день.
	var climate: RefCounted = models["climate"]
	var surface: RefCounted = models["surface"]
	var nature: RefCounted = models["nature"]
	var fire: RefCounted = models["fire"]
	_check(climate.set_day(day), "Климат готов для дня %d" % day)
	_check(surface.advance_climate_day(climate),
		"Почва готова для дня %d" % day)
	nature.advance_day(day)
	fire.advance_day(day)


func _verify_turbidity(models: Dictionary, ocean: Vector2i) -> void:
	# Сравниваем те же реальные вершины воды без и с пожарным
	# реестром. Меняться должен только цвет, а не Y, UV или сток.
	var world: RefCounted = models["world"]
	var hydro: RefCounted = models["hydro"]
	var fire: RefCounted = models["fire"]
	var chunk: Vector2i = world.config.chunk_of(ocean)
	var pristine: Array = Water.prepare_arrays(world, hydro, chunk)
	var dirty: Array = Water.prepare_arrays(world, hydro, chunk, null, fire)
	_check(not pristine.is_empty() and not dirty.is_empty(),
		"Океан действительно создал оба варианта водного меша")
	if pristine.is_empty() or dirty.is_empty():
		return
	var a: PackedColorArray = pristine[Mesh.ARRAY_COLOR]
	var b: PackedColorArray = dirty[Mesh.ARRAY_COLOR]
	_check(a.size() == b.size(), "Мутность не добавляет вершин")
	_check(pristine[Mesh.ARRAY_VERTEX] == dirty[Mesh.ARRAY_VERTEX]
		and pristine[Mesh.ARRAY_TEX_UV] == dirty[Mesh.ARRAY_TEX_UV]
		and pristine[Mesh.ARRAY_TEX_UV2] == dirty[Mesh.ARRAY_TEX_UV2],
		"Мутность не меняет геометрию и движение воды")
	var altered := 0
	for i in range(mini(a.size(), b.size())):
		if b[i].r > a[i].r + 0.02 and b[i].b < a[i].b - 0.01:
			altered += 1
	_check(altered > 0, "Настоящая водная сетка становится мутной")
	_check(WaterShader.code.contains("vec3 base = COLOR.rgb"),
		"Шейдер Godot действительно читает переданные цвета PBR-меша")


func _state(models: Dictionary) -> Dictionary:
	# WorldSave должен переживать водный и донный запас вместе со
	# всеми прежними климатическими и пожарными подсистемами.
	var world: RefCounted = models["world"]
	var hydro: RefCounted = models["hydro"]
	var surface: RefCounted = models["surface"]
	var climate: RefCounted = models["climate"]
	return {
		"world": world, "hydro": hydro, "surface": surface,
		"climate": climate, "nature": models["nature"], "fire": models["fire"],
		"weather": Weather.new(world, climate, surface, hydro),
		"natural": Processes.new(world, hydro, surface, climate),
		"disasters": Disasters.new(world, hydro, surface, climate)
	}


func _test() -> void:
	# Задаём конечную реальную порцию в морской клетке. Зола
	# изначально только во взвеси; осадок ещё отсутствует.
	var models: Dictionary = _models()
	var world: RefCounted = models["world"]
	var hydro: RefCounted = models["hydro"]
	var fire: RefCounted = models["fire"]
	var ocean := _find_cell(world, hydro, true)
	var dry := _find_cell(world, hydro, false)
	if ocean.x < 0 or dry.x < 0:
		return
	var ocean_index: int = hydro.cell_index(ocean)
	var saved: Dictionary = fire.to_data()
	saved["suspended_ash"] = [[ocean_index, 160]]
	_check(fire.load_data(saved), "Исходная взвесь загружена в формат v7")
	_check(fire.ash_mass_total() == 160
		and fire.deposited_ash_total() == 0,
		"160 единиц принадлежат только движущейся водной фазе")
	_check(fire.ash_turbidity_at(ocean) == 1.0,
		"Мутность соответствует конечной взвеси, а не осадку")
	_verify_turbidity(models, ocean)
	var before_world: Dictionary = world.to_data()
	var before_hydro: Dictionary = hydro.to_snapshot()

	# Морское дно за день принимает 25% (40 из 160) запасов,
	# оставшиеся 120 могут течь далее. Никакой массы не пропадает.
	_advance(models, 2)
	_check(fire.deposited_ash_at(ocean) == 40
		and fire.deposited_ash_total() == 40,
		"Океан осадил 40 физических единиц золы")
	_check(fire.suspended_ash_total() == 120
		and fire.ash_mass_total() == 160,
		"Осаждение не создало и не уничтожило зольную массу")
	var current: Dictionary = fire.to_data()
	_check(fire.advance_day(2).is_empty() and fire.to_data() == current,
		"Повтор тех же суток не осаждает золу второй раз")

	# Сейв проходит атомарную проверку всех природных реестров.
	var snapshot: Dictionary = Save.capture(_state(models))
	_check(not snapshot.is_empty(), "Полный мир с осадком сохраняется")
	if not snapshot.is_empty():
		var restored: Dictionary = Save.restore(
			JSON.parse_string(JSON.stringify(snapshot)))
		_check(not restored.is_empty(), "Полный мир с осадком загружается")
		if not restored.is_empty():
			_check(restored["fire"].to_data() == fire.to_data()
				and restored["fire"].ash_mass_total() == 160,
				"WorldSave сохранил оба состояния конечной золы")

	# Некорректные записи не способны частично изменить живой мир.
	_check(int(current["version"]) == 8
		and not current["deposited_ash"].is_empty(),
		"Сохранение v7 содержит физическое дно")
	var invalid: Dictionary = current.duplicate(true)
	invalid["deposited_ash"].append(invalid["deposited_ash"][0].duplicate())
	_check(not fire.load_data(invalid) and fire.to_data() == current,
		"Дубли осадка отклоняются атомарно")
	invalid = current.duplicate(true)
	invalid["deposited_ash"][0][1] = 1001
	_check(not fire.load_data(invalid) and fire.to_data() == current,
		"Осадок больше лимита отклонён")
	invalid = current.duplicate(true)
	invalid["deposited_ash"][0][1] = 1.5
	_check(not fire.load_data(invalid) and fire.to_data() == current,
		"Дробное количество осадка отклонено")
	invalid = current.duplicate(true)
	invalid["deposited_ash"][0][0] = world.config.width * world.config.height
	_check(not fire.load_data(invalid) and fire.to_data() == current,
		"Осадок за пределами карты отклонён")

	# Старый v6 хранит взвесь, но не имеет донных отложений.
	# Совместимость v1–v5 проверяется существующими smoke-тестами.
	var prior: Dictionary = current.duplicate(true)
	prior["version"] = 6
	prior.erase("deposited_ash")
	var legacy := Fire.new(world, hydro, models["surface"],
		models["climate"], models["nature"])
	_check(legacy.load_data(prior)
		and legacy.deposited_ash_total() == 0
		and legacy.suspended_ash_total() == fire.suspended_ash_total(),
		"Старый v6 читается без выдуманного осадка")

	# Проверяем сухое дно: вода пропала, но масса не может
	# бесследно исчезнуть или повторно окрашивать бывшее русло.
	saved = current.duplicate(true)
	saved["suspended_ash"] = [[hydro.cell_index(dry), 60]]
	_check(fire.load_data(saved), "Тестовая взвесь бывшего русла загружена")
	var prior_deposit: int = fire.deposited_ash_total()
	_advance(models, 3)
	_check(fire.suspended_ash_at(dry) == 0
		and fire.deposited_ash_at(dry) == 60,
		"При высыхании русла зола целиком остаётся на дне")
	_check(fire.ash_turbidity_at(dry) == 0.0
		and fire.deposited_ash_total() >= prior_deposit + 60,
		"Сухое дно не даёт фиктивной мутной воды")
	_check(before_world == world.to_data()
		and before_hydro == hydro.to_snapshot(),
		"Новые слои не меняют рельеф, водосбор и море")


func _run() -> void:
	# Один воспроизводимый тест охватывает физику, графический
	# цвет настоящих вершин, обратную совместимость и сейвы.
	_test()
	if not failures.is_empty():
		for reason in failures:
			printerr("11.5/F5b2e2: ", reason)
		quit(1)
		return
	print("11.5/F5b2e2: осадок, мутная вода, баланс и JSON — успешно.")
	quit(0)


func _initialize() -> void:
	# Реальные RefCounted-модели запускаем после создания SceneTree.
	call_deferred("_run")
