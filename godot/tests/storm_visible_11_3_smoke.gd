extends SceneTree
## Сквозная проверка игрового шторма: от явной команды до физических
## деревьев, кадровой анимации, порывов и сохранённого результата.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const Felling = preload("res://scripts/nature_felling_visual.gd")
const Renderer = preload("res://scripts/nature_renderer.gd")
const Weather = preload("res://scripts/weather_events.gd")
const Processes = preload("res://scripts/natural_processes.gd")
const Disasters = preload("res://scripts/natural_disasters.gd")
const Runner = preload("res://scripts/world_day_runner.gd")
const Visual = preload("res://scripts/weather_visual_state.gd")
const FX = preload("res://scripts/weather_fx_controller.gd")
const Terrain = preload("res://scripts/terrain.gd")

var failures: Array[String] = []


func _check(ok: bool, message: String) -> void:
	# Собираем все ошибки, чтобы регрессия была понятна по логам CI.
	if not ok:
		failures.append(message)


func _run() -> void:
	# Настоящие модели карты используют обычную физику дневного цикла.
	var seed := 1729
	var world := Map.new(Config.new(96, 80, seed, 16, 32))
	var hydro := Hydro.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	var climate := Climate.new(world, hydro)
	climate.rebuild()
	climate.set_day(1)
	surface.advance_climate_day(climate)
	hydro.apply_rainfall_map(surface.runoff_map())
	var nature := Nature.new(world, hydro, surface, climate)
	_check(nature.generate(), "Природа создана")
	var strikes := Weather.new(world, climate, surface, hydro)
	var processes := Processes.new(world, hydro, surface, climate)
	var disasters := Disasters.new(world, hydro, surface, climate)
	var runner := Runner.new(world, hydro, surface, climate,
		strikes, processes, disasters, nature)

	# Детерминированно ищем дерево, которое должен повалить день 2.
	var target: Dictionary = {}
	for item in nature.to_data()["objects"]:
		if item[1] != "дерево" or item[9] != "целое":
			continue
		var id := int(item[0])
		var x := int(item[3])
		var y := int(item[4])
		if x < 6 or y < 6 or x >= 90 or y >= 74:
			continue
		if posmod(2 - id, 8) == 0 or int(item[7]) <= 0:
			continue
		if Terrain.hash2(x, y, seed + 2 * 31 + 3173) >= 0.85:
			continue
		target = nature.object_at(id)
		break
	if target.is_empty():
		_check(false, "Для теста существует доступное дерево")
		_finish()
		return
	var cell := Vector2i(int(target["x"]), int(target["y"]))
	var wood_before: int = nature.wood_total()
	var before_map: String = JSON.stringify(world.to_data())

	# Диагностическая команда идёт через штатный Runner и Registry,
	# а не создаёт декоративное событие без физических последствий.
	runner.test_storm_cell = cell
	runner.run_day()
	var result: Dictionary = runner.last_result
	var trials := 0
	for hazard in result["hazards"]:
		if hazard.get("source", "") == "диагностика":
			trials += 1
			_check(hazard["kind"] == "шторм" and hazard["cell"] == cell
				and float(hazard["severity"]) == 1.0,
				"Проба записана отдельным физическим событием")
	_check(trials == 1 and runner.test_storm_cell.x < 0,
		"Испытание действует только один день")
	var fallen: Dictionary = nature.object_at(int(target["id"]))
	_check(fallen["state"] == "пень" and int(fallen["fall_angle_deg"]) >= 0,
		"Шторм действительно валит дерево по направлению ветра")
	var windfalls: Array = result["windfalls"]
	_check(not windfalls.is_empty(), "Runner передаёт реальные переходы")

	# Визуальный эффект получает исходное дерево и физический угол.
	# Никакие частицы и Tween не создают дополнительную древесину.
	var visual_found := false
	for entry in windfalls:
		if int(entry["before"]["id"]) != int(target["id"]):
			continue
		visual_found = true
		var angle: int = entry["fall_angle_deg"]
		_check(angle == int(fallen["fall_angle_deg"]),
			"Угол анимации точно совпадает с сохранённым углом")
		var falling: Node3D = Felling.make_visual(
			world, entry["before"], 1.0, false, angle)
		_check(falling != null, "Создаётся видимое падающее дерево")
		if falling != null:
			_check(absf(wrapf(falling.rotation.y - deg_to_rad(float(angle)),
				-PI, PI)) < 0.001,
				"Анимация смотрит в физическую сторону падения")
			root.add_child(falling)
			Felling.animate(falling)
			# Для smoke достаточно создать Tween; завершение анимации
			# не является условием физического результата.
			root.remove_child(falling)
			falling.free()
		break
	_check(visual_found, "Фоновый расчёт отдаёт именно поваленное дерево")

	# Штормовые полосы показывают направление события, а не изменяют
	# модель климата; обычное выключение эффектов их скрывает.
	var fx := FX.new()
	root.add_child(fx)
	var snapshot: Dictionary = Visual.sample(
		climate, world.config, Vector2(cell), 36.0)
	var direction: Vector2 = climate.wind_direction_at_index(
		hydro.cell_index(cell))
	fx.show_storm_event(1.0, direction, 3.0)
	fx.apply_snapshot(snapshot, Vector2(cell), 3.0, 36.0, seed)
	var gusts: GPUParticles3D = fx.get("_gusts")
	_check(gusts != null and gusts.emitting and gusts.amount_ratio > 0.1,
		"Настоящий шторм включает отдельные GPU-порывы")
	if gusts != null:
		var wind_material: ParticleProcessMaterial = gusts.process_material
		_check(Vector2(wind_material.direction.x,
			wind_material.direction.z).dot(direction) > 0.999,
			"Порывы направлены по физическому ветру")
	fx.set_effects_enabled(false)
	_check(gusts != null and not gusts.emitting,
		"Отключение FX скрывает порывы")
	root.remove_child(fx)
	fx.free()

	Renderer.set_wind_direction(direction)
	_check(nature.wood_total() == wood_before,
		"Ни анимация, ни испытание не создают древесину")
	var saved: Dictionary = JSON.parse_string(JSON.stringify(nature.to_data()))
	var restored := Nature.new(world, hydro, surface, climate)
	_check(restored.load_data(saved) and restored.to_data() == nature.to_data(),
		"Направленный ветровал переживает загрузку")
	_check(JSON.stringify(world.to_data()) == before_map,
		"Шторм не изобретает новый рельеф")

	# Следующий день не дублирует диагностический шторм.
	runner.run_day()
	var next_trial := false
	for hazard in runner.last_result["hazards"]:
		if hazard.get("source", "") == "диагностика":
			next_trial = true
	_check(not next_trial, "Тестовый шторм не повторяется сам")
	_finish()


func _finish() -> void:
	# Возвращаем ненулевой код CI, если нарушен хоть один инвариант.
	if not failures.is_empty():
		for error in failures:
			printerr("11.3/V2.3: ", error)
		quit(1)
		return
	print("11.3/V2.3: физический шторм, анимация, порывы и сохранения — успешно")
	quit(0)


func _initialize() -> void:
	# GPU-эмиттеры создаются после инициализации дерева узлов.
	call_deferred("_run")
