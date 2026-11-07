extends SceneTree
## 11.8/P2 — совместные физические последствия нескольких бедствий.
## Никаких дополнительных реестров: тест читает реальные модели мира.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const Weather = preload("res://scripts/weather_events.gd")
const Natural = preload("res://scripts/natural_processes.gd")
const Disasters = preload("res://scripts/natural_disasters.gd")
const Fire = preload("res://scripts/fire_registry.gd")
const Landscape = preload("res://scripts/landscape_events.gd")
const Runner = preload("res://scripts/world_day_runner.gd")
const Save = preload("res://scripts/world_save.gd")
const Aftermath = preload("res://scripts/world_aftermath.gd")
const Terrain = preload("res://scripts/terrain.gd")

var failures: Array[String] = []


func _check(ok: bool, reason: String) -> void:
	# Показываем каждое нарушенное свойство отдельно, чтобы одна
	# ошибка не скрывала потерю массы или неверное восстановление.
	if not ok:
		failures.append(reason)


func _tree(world: RefCounted, cell: Vector2i, stock: int) -> Dictionary:
	# Стабильные ID и поля соответствуют единственному NatureRegistry.
	# Так исключаем зависимость от случайной плотности леса.
	return {
		"id": cell.y * world.config.width + cell.x + 1,
		"kind": "дерево", "species": "сосна",
		"x": cell.x, "y": cell.y, "age_days": 9 * 96 + 32,
		"health": 1000, "wood_units": stock, "fallen_wood": 0,
		"state": "целое", "cut_progress": 0, "dead_since_day": -1,
		"fallen_since_day": -1, "fall_angle_deg": -1, "radius": 0.21
	}


func _models(seed: int) -> Dictionary:
	# Склон имеет реальный водосбор; наносы и кратер меняют
	# вершины, а погода затем действует по изменённой высоте.
	var world := Map.new(Config.new(80, 64, seed, 16, 32))
	var heights := {}
	for y in range(65):
		for x in range(81):
			heights[Vector2i(x, y)] = 15.0 + (80.0 - float(x)) * 0.12
	_check(world.apply_vertex_changes(heights), "Контрольный склон создан")
	world.take_dirty_chunks()
	var hydro := Hydro.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	var climate := Climate.new(world, hydro)
	climate.rebuild()
	_check(climate.set_day(1), "Климат первого дня установлен")
	_check(surface.advance_climate_day(climate), "Суточный грунт рассчитан")
	_check(hydro.apply_rainfall_map(surface.runoff_map()), "Водосбор обновлён")

	var nature := Nature.new(world, hydro, surface, climate)
	_check(nature.generate(), "Физический лес создан")
	nature._objects.clear()
	nature._chunks.clear()
	# Для урагана выбираем дерево, которое действительно падает
	# по детерминированному порогу seed и второго игрового дня.
	var wind_cell := Vector2i(-1, -1)
	for x in range(35, 45):
		if Terrain.hash2(x, 30, seed + 2 * 31 + 3173) < 0.9:
			wind_cell = Vector2i(x, 30)
			break
	_check(world.config.contains_cell(wind_cell), "Найдено дерево для ветровала")
	if not world.config.contains_cell(wind_cell):
		wind_cell = Vector2i(40, 30)
	var distant := Vector2i(74, 57)
	for item in [_tree(world, wind_cell, 21), _tree(world, distant, 8)]:
		nature._objects[int(item["id"])] = item
		nature._index(item)

	var weather := Weather.new(world, climate, surface, hydro)
	var natural := Natural.new(world, hydro, surface, climate)
	var disasters := Disasters.new(world, hydro, surface, climate)
	var fire := Fire.new(world, hydro, surface, climate, nature)
	return {
		"world": world, "hydro": hydro, "surface": surface,
		"climate": climate, "nature": nature, "weather": weather,
		"natural": natural, "disasters": disasters, "fire": fire,
		"cell": wind_cell, "distant": distant,
		"runner": Runner.new(world, hydro, surface, climate,
			weather, natural, disasters, nature, fire)
	}


func _add_sediment(state: Dictionary, target: Vector2i) -> bool:
	# Нанос создаём через настоящий перенос Surface: исходная
	# высота теряет ровно столько, сколько получает следующая.
	var surface: RefCounted = state["surface"]
	var world: RefCounted = state["world"]
	for y in range(5, world.config.height - 4):
		for x in range(5, world.config.width - 4):
			var source := Vector2i(x, y)
			if source == target or surface.soil_depth_at_index(
					state["hydro"].cell_index(source)) < 0.08:
				continue
			if surface.transfer_sediment(source, target, 0.02):
				return state["runner"].synchronize_world()
	return false


func _combined_impacts(state: Dictionary) -> Dictionary:
	var world: RefCounted = state["world"]
	var surface: RefCounted = state["surface"]
	var climate: RefCounted = state["climate"]
	var hydro: RefCounted = state["hydro"]
	var nature: RefCounted = state["nature"]
	var fire: RefCounted = state["fire"]
	var cell: Vector2i = state["cell"]
	var i: int = hydro.cell_index(cell)
	var id := cell.y * world.config.width + cell.x + 1
	var far: Vector2i = state["distant"]
	var far_id := far.y * world.config.width + far.x + 1

	# Берём реальную потерю топлива из NatureRegistry и передаём её
	# тем же методам физического FireRegistry, что используют пожарные
	# тесты. Не создаём бесплатную древесину или копию золы.
	var starting_wood: int = nature.wood_total()
	var old_tree: Dictionary = nature.object_at(id)
	_check(nature.burn_object(id, 120, 1),
		"Пожар действительно израсходовал древесину дерева")
	var remaining_wood: int = int(nature.object_at(id)["wood_units"])
	var spent: int = int(old_tree["wood_units"]) - remaining_wood
	_check(spent > 0 and nature.wood_total() == starting_wood - spent,
		"Сгоревшее топливо вычтено из единственного запаса древесины")
	var changed := {}
	fire._scorch(cell, 120, changed)
	fire._deposit_charcoal(cell, spent * 2, changed)
	nature.refresh_ground_visuals(changed)
	_check(fire.soil_damage_at(cell) > 0.0
		and fire.scorched_at(cell) > 0.0
		and fire.charcoal_at(cell) == spent * 2,
		"Ожог, гарь и конечный уголь находятся в FireRegistry")

	# Ураган обрабатывается естественным физическим путём суток.
	# Древесина переносится в поваленный ствол, а не появляется вновь.
	_check(climate.set_day(2), "Следующие сутки начались")
	_check(surface.advance_climate_day(climate), "Погода второго дня рассчитана")
	hydro.apply_rainfall_map(surface.runoff_map())
	var storm: Array[Dictionary] = [
		{"kind": "ураган", "cell": cell, "severity": 1.0, "day": 2}
	]
	var no_strikes: Array[Dictionary] = []
	nature.advance_day(2, storm, no_strikes, fire)
	fire.advance_day(2, no_strikes)
	_check(nature.object_at(id)["state"] == "пень"
		and int(nature.object_at(id)["fallen_wood"]) == remaining_wood
		and int(nature.object_at(id)["wood_units"]) == 0,
		"Ветровал перевёл остаток топлива в одну лежащую древесину")
	_check(nature.wood_total() == starting_wood - spent,
		"Ветровал не дублирует уголь, ствол и лежащую древесину")
	_check(nature.object_at(far_id)["state"] == "целое",
		"Далёкое дерево не затронуто локальным бедствием")

	# След геологического события использует тот же WorldMap,
	# что уже затронутый пожаром и ветровалом лес.
	var center := Vector2(cell) + Vector2(0.5, 0.5)
	var crater: Dictionary = Landscape.new(world).apply(
		"кратер", center, 6.0, 1.6)
	_check(not crater.is_empty(), "Кратер изменил настоящий рельеф")
	_check(state["runner"].synchronize_world(),
		"Водосбор и грунты пересчитаны после удара")
	nature.apply_landscape_impact("кратер", center, 6.0, 1.0, 2)
	_check(surface.register_geological_scar("кратер", center, 6.0, 0.9),
		"Геологический след возник поверх существующего ожога")
	_check(nature.wood_total() == starting_wood - spent,
		"Кратер не создаёт вторую копию упавшего ствола")
	_check(fire.soil_damage_at(cell) > 0.0 and fire.charcoal_at(cell) > 0,
		"Кратер не стирает пожарную историю")

	# Физический перенос наносов учитывает две вершины. После
	# повторной синхронизации шрам почвы остаётся на своей клетке.
	_check(_add_sediment(state, cell), "Нанос реально перемещён по склону")
	_check(surface.profile_at(cell)["sediment"] > 0.0,
		"Нанос существует как конечный ресурс грунта")
	_check(surface.geological_scar_at_index(i) > 0.0,
		"Перенос наносов не лечит геологическое разрушение")

	# Локальная снежная буря действует существующим ядром осадков
	# Surface; снег появляется поверх золы без удаления ожога.
	surface._apply_weather(i, 1.5, -10.0)
	surface._update_snow_coverage()
	var report: Dictionary = Aftermath.at(
		cell, world, surface, nature, fire, hydro)
	_check(float(report["snow"]) > 0.10
		and float(report["sediment"]) > 0.0
		and float(report["geological_scar"]) > 0.0
		and float(report["fire_damage"]) > 0.0
		and float(report["scorched"]) > 0.0
		and int(report["charcoal"]) > 0
		and int(report["fallen_wood"]) == remaining_wood,
		"Семь независимых физических следов сосуществуют в одной клетке")
	_check(report["object_state"] == "пень",
		"Сводка читает реальный объект NatureRegistry")
	_check(Aftermath.at(Vector2i(-1, -1),
		world, surface, nature, fire, hydro).is_empty(),
		"Сводка не выдумывает следы вне карты")

	# Далёкая камера читает другой участок: обращение к сводке
	# не меняет снег, огонь, рельеф и прочие физические ресурсы.
	var before_surface: Dictionary = surface.to_snapshot()
	var before_fire: Dictionary = fire.to_data()
	var before_nature: Dictionary = nature.to_data()
	var distant_report := Aftermath.at(far, world, surface, nature, fire, hydro)
	_check(distant_report.get("fallen_wood", -1) == 0,
		"После ухода камеры дальняя клетка независима")
	var again: Dictionary = Aftermath.at(cell, world, surface, nature, fire, hydro)
	_check(again == report and before_surface == surface.to_snapshot()
		and before_fire == fire.to_data()
		and before_nature == nature.to_data(),
		"Повторный вход камеры не пересоздаёт следы или ресурсы")
	return {"initial": report, "wood": starting_wood - spent}


func _resume(state: Dictionary, initial: Dictionary) -> void:
	# Полный снимок должен содержать сразу все типы последствий,
	# а не одну декоративную метку последнего происшествия.
	var save: Dictionary = Save.capture(state)
	_check(not save.is_empty() and save.has("fire") and save.has("nature"),
		"Полный WorldSave содержит лес, пожар и грунт")
	if save.is_empty():
		return
	var json: Variant = JSON.parse_string(JSON.stringify(save))
	_check(json is Dictionary, "Полный JSON сериализован")
	if not (json is Dictionary):
		return
	var recovered: Dictionary = Save.restore(json)
	_check(not recovered.is_empty(), "Смешанный мир полностью восстановлен")
	if recovered.is_empty():
		return
	var cell: Vector2i = state["cell"]
	var world: RefCounted = state["world"]
	var restored: Dictionary = Aftermath.at(cell, recovered["world"],
		recovered["surface"], recovered["nature"],
		recovered["fire"], recovered["hydro"])
	_check(restored["geological_scar"] == initial["geological_scar"]
		and restored["fire_damage"] == initial["fire_damage"]
		and restored["fallen_wood"] == initial["fallen_wood"]
		and restored["snow"] == initial["snow"]
		and restored["sediment"] == initial["sediment"],
		"После загрузки совпадают все основные природные последствия")
	_check(state["surface"].to_snapshot() == recovered["surface"].to_snapshot()
		and state["fire"].to_data() == recovered["fire"].to_data()
		and state["nature"].to_data() == recovered["nature"].to_data()
		and world.to_data() == recovered["world"].to_data(),
		"Полный JSON не теряет наносы, древесину, высоты, ожоги и шрамы")

	# При продолжении календаря разные реестры восстанавливаются
	# с собственной скоростью: пожар может исчезнуть, пока
	# геологическая травма ещё понижает плодородие.
	var initial_rock: float = float(initial["geological_scar"])
	var initial_fire: float = float(initial["fire_damage"])
	var initial_wood: int = int(initial["fallen_wood"])
	var before_day := state["climate"].day
	for step in range(1, 193):
		state["runner"].run_day()
		recovered["runner"].run_day()
		if step % 12 == 0 or step == 1:
			_check(state["world"].to_data() == recovered["world"].to_data()
				and state["surface"].to_snapshot() == recovered["surface"].to_snapshot()
				and state["fire"].to_data() == recovered["fire"].to_data()
				and state["nature"].to_data() == recovered["nature"].to_data(),
				"После JSON четыре физические системы идут одинаково, шаг %d" % step)
			var read: Dictionary = Aftermath.at(cell, state["world"],
				state["surface"], state["nature"],
				state["fire"], state["hydro"])
			_check(float(read["geological_scar"]) >= 0.0
				and float(read["geological_scar"]) <= 1.0
				and float(read["fire_damage"]) >= 0.0
				and float(read["fire_damage"]) <= 1.0
				and int(read["fallen_wood"]) >= 0,
				"Следы остаются физически ограниченными, шаг %d" % step)
	_check(state["climate"].day == before_day + 192,
		"Два полных сезонных года рассчитаны")
	var after: Dictionary = Aftermath.at(cell, state["world"],
		state["surface"], state["nature"],
		state["fire"], state["hydro"])
	_check(float(after["geological_scar"]) < initial_rock,
		"За два сезона разрушенный грунт постепенно заживает")
	_check(float(after["fire_damage"]) < initial_fire,
		"Почвенный ожог восстанавливается независимо от геологии")
	_check(int(after["fallen_wood"]) <= initial_wood,
		"Лежащая древесина не размножается от смены сезонов")
	_check(recovered["runner"].run_day == state["runner"].run_day
		or recovered["surface"].to_snapshot() == state["surface"].to_snapshot(),
		"Восстановление не расходится с независимым календарём")


func _initialize() -> void:
	# События повторяем на двух разных физических seed, чтобы
	# поведение не зависело от удачной единственной раскладки биома.
	for seed in [2411, 7291]:
		var state: Dictionary = _models(seed)
		var values: Dictionary = _combined_impacts(state)
		_resume(state, values["initial"])
	if not failures.is_empty():
		for reason in failures:
			push_error("11.8/P2: " + reason)
		quit(1)
		return
	print("11.8/P2: совместные следы, 2 seed, сезонные циклы и JSON — успешно.")
	quit(0)
