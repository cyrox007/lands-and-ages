extends SceneTree
## 11.7/RF4 — сезонная нагрузочная регрессия геологических последствий.
## Время CI измеряет CPU-модель, а не FPS реального ПК или Android.

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

const Seeds := [1729, 4471, 8429]
const FinalDay := 96
const EventInterval := 16
const SnapshotInterval := 32

var failures: Array[String] = []


func _check(ok: bool, message: String) -> void:
	# Полное испытание должно показать все нарушенные инварианты,
	# а не прерваться по первой случайной проблеме конкретного seed.
	if not ok:
		failures.append(message)


func _path() -> String:
	# Путь отчёта можно передать из CI, а локально используем
	# стандартную пользовательскую область Godot.
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--out="):
			return argument.trim_prefix("--out=")
	return "user://landscape-11-7-rf4-stress.json"


func _models(seed: int) -> Dictionary:
	# Используем обычный генератор, климат, дождевой сток и лес.
	# Контрольный мир имеет четыре области по 32 клетки и несколько
	# физических чанков: последствия не сводятся к одной клетке.
	var world := Map.new(Config.new(80, 64, seed, 16, 32))
	var hydro := Hydro.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	var climate := Climate.new(world, hydro)
	climate.rebuild()
	_check(climate.set_day(1), "Не установлен первый день seed %d" % seed)
	_check(surface.advance_climate_day(climate),
		"Не рассчитан первый день почвы seed %d" % seed)
	_check(hydro.apply_rainfall_map(surface.runoff_map()),
		"Не рассчитан первый день водосбора seed %d" % seed)
	var nature := Nature.new(world, hydro, surface, climate)
	_check(nature.generate(), "Не создан природный реестр seed %d" % seed)
	var weather := Weather.new(world, climate, surface, hydro)
	var natural := Natural.new(world, hydro, surface, climate)
	var disasters := Disasters.new(world, hydro, surface, climate)
	var fire := Fire.new(world, hydro, surface, climate, nature)
	return {
		"world": world, "hydro": hydro, "surface": surface,
		"climate": climate, "nature": nature, "weather": weather,
		"natural": natural, "disasters": disasters, "fire": fire,
		"runner": Runner.new(world, hydro, surface, climate,
			weather, natural, disasters, nature, fire)
	}


func _center(state: Dictionary, step: int) -> Vector2:
	# Выбираем безопасный участок внутри мира с конечной
	# высотой; на следующем цикле меняем место удара и породу.
	# Нельзя незаметно принять отсутствие подходящего участка.
	var world: RefCounted = state["world"]
	var hydro: RefCounted = state["hydro"]
	var options: Array[Vector2] = []
	for y in range(16, 49, 8):
		for x in range(16, 65, 8):
			var cell := Vector2i(x, y)
			var index: int = hydro.cell_index(cell)
			if index < 0 or hydro.has_water(index):
				continue
			var point := Vector2(cell) + Vector2(0.5, 0.5)
			var h: float = world.height_at(point)
			if h > -8.0 and h < 33.0:
				options.append(point)
	if options.is_empty():
		_check(false, "Не найден безопасный геологический участок")
		return Vector2(40.5, 32.5)
	return options[posmod(step * 17 + world.config.world_seed, options.size())]


func _resource_invariants(nature: RefCounted, label: String) -> void:
	# Состояние деревьев хранит два непересекающихся запаса:
	# стоящую и лежащую древесину. Каждый ID должен быть уникален.
	var used := {}
	for object in nature.to_data()["objects"]:
		var id: int = int(object[0])
		_check(not used.has(id), label + ": два объекта с одним ID")
		used[id] = true
		_check(int(object[7]) >= 0 and int(object[8]) >= 0,
			label + ": отрицательный запас древесины")
		if str(object[9]) == "пень":
			_check(int(object[7]) == 0,
				label + ": пень одновременно хранит стоящую древесину")


func _geometry(state: Dictionary, step: int) -> bool:
	# Сезонный удар применяется после завершения игрового дня:
	# ресурс изменяется только при успешном физическом событии.
	var kind := ["кратер", "просадка", "поднятие"][step % 3]
	var world: RefCounted = state["world"]
	var nature: RefCounted = state["nature"]
	var center := _center(state, step)
	var old_wood: int = nature.wood_total()
	var before: int = world.revision
	var result: Dictionary = Landscape.new(world).apply(
		kind, center, 6.0, 0.45)
	_check(not result.is_empty(),
		"Сезонное событие %s не применилось: %s" % [kind, center])
	if result.is_empty():
		return false
	_check(world.revision == before + 1, "Двойная ревизия за один удар")
	nature.apply_landscape_impact(kind, center, 6.0, 0.85,
		state["climate"].day)
	_check(nature.wood_total() == old_wood,
		"Деформация не сохранила сумму древесины")
	_check(state["runner"].synchronize_world(),
		"Не согласованы водосборы после геологии")
	_check(state["hydro"]._terrain_revision == world.revision \
			and state["surface"]._terrain_revision == world.revision \
			and state["climate"]._terrain_revision == world.revision,
		"Ревизии климата, грунтов и водосборов разошлись")
	_resource_invariants(nature, "Сезонное событие")
	return true


func _snapshot(state: Dictionary) -> Dictionary:
	# Сохраняем единый снимок всех физических подсистем. После
	# чтения JSON новые модели не делят старые PackedArray или IDs.
	var snapshot: Dictionary = Save.capture(state)
	_check(not snapshot.is_empty(), "WorldSave отказался сохранять сезон")
	if snapshot.is_empty():
		return state
	var parsed: Variant = JSON.parse_string(JSON.stringify(snapshot))
	_check(parsed is Dictionary, "Снимок не преобразован в JSON")
	if not (parsed is Dictionary):
		return state
	var restored: Dictionary = Save.restore(parsed)
	_check(not restored.is_empty(), "Сезонный мир не восстановлен")
	if restored.is_empty():
		return state
	for name in ["world", "nature", "fire", "climate"]:
		_check(state[name].to_data() == restored[name].to_data(),
			"Восстановление изменило данные " + name)
	_check(state["surface"].to_snapshot() == restored["surface"].to_snapshot()
		and state["hydro"].to_snapshot() == restored["hydro"].to_snapshot(),
		"Восстановление изменило наносы, снег или речные бассейны")
	return restored


func _percentile(values: Array[float], fraction: float) -> float:
	# Статистика нагрузки — только для сопоставления прогонов
	# программного CPU: это не гарантированное время мобильного кадра.
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	var index := clampi(ceili(float(sorted.size()) * fraction) - 1,
		0, sorted.size() - 1)
	return sorted[index]


func _season(seed: int) -> Dictionary:
	# Проходим весь 96-дневный игровой год с шестью физическими
	# деформациями и тремя полными загрузками промежуточных миров.
	var state: Dictionary = _models(seed)
	var samples: Array[float] = []
	var impacts := 0
	var loads := 0
	var peak_objects := 0
	var last_revision: int = state["world"].revision
	for day in range(2, FinalDay + 1):
		var started := Time.get_ticks_usec()
		state["runner"].run_day()
		_check(state["climate"].day == day
			and state["nature"].last_day == day,
			"Нарушен суточный календарь seed %d, день %d" % [seed, day])
		_check(state["world"].revision >= last_revision,
			"Ревизия мира пошла назад")
		last_revision = state["world"].revision
		if day % EventInterval == 0:
			if _geometry(state, int(day / EventInterval)):
				impacts += 1
		if day % SnapshotInterval == 0:
			state = _snapshot(state)
			loads += 1
		_check(state["world"]._dirty.is_empty(),
			"Не сброшены изменённые чанки после суточной физики")
		peak_objects = maxi(peak_objects, state["nature"].count())
		samples.append(float(Time.get_ticks_usec() - started) / 1000.0)
	_resource_invariants(state["nature"], "Конец года")
	_check(state["climate"].day == FinalDay,
		"Год не дошёл до последних суток")
	_check(impacts == 6 and loads == 3,
		"Деформации и полные снимки выполнены не все")
	return {
		"seed": seed, "days": FinalDay, "impacts": impacts,
		"full_restore_cycles": loads, "peak_nature_objects": peak_objects,
		"day_cpu_ms_p50": _percentile(samples, 0.50),
		"day_cpu_ms_p95": _percentile(samples, 0.95),
		"day_cpu_ms_peak": _percentile(samples, 1.0),
		"last_day": state["climate"].day,
		"world_revision": state["world"].revision
	}


func _initialize() -> void:
	# Делаем измерения в headless CI без GUI. Отчёт хранит платформу,
	# время CPU и seed; заявлять FPS ПК или телефона здесь нельзя.
	var reports := []
	for seed in Seeds:
		reports.append(_season(seed))
	var path := _path()
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(path.get_base_dir()))
	var output := FileAccess.open(path, FileAccess.WRITE)
	_check(output != null, "Не создан JSON нагрузочной регрессии")
	var manifest := {
		"stage": "11.7", "subtask": "RF4",
		"mode": "headless CPU simulation", "renderer": "headless",
		"hardware_fps_verified": false,
		"artistic_approval": false,
		"seeds": reports, "checks_passed": failures.is_empty(),
		"engine": Engine.get_version_info().get("string", "unknown")
	}
	if output != null:
		output.store_string(JSON.stringify(manifest, "\t") + "\n")
		output.close()
	if not failures.is_empty():
		for error in failures:
			push_error("11.7/RF4/STRESS: " + error)
		quit(1)
		return
	print("11.7/RF4/STRESS: три игровых года, 18 деформаций и 9 сохранений — успешно")
	quit(0)
