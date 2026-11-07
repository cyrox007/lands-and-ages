extends SceneTree
## 11.10 — сквозной долгосрочный аудит физической карты и визуализации.
## 3 seed × 96 суток; два независимых мира, периодические JSON/файловые
## сохранения, бедствия, геология, водосбор, лес, огонь и кадры камеры.
## Интервалы CPU относятся только к headless CI, не к аппаратному FPS.

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
const Runner = preload("res://scripts/world_day_runner.gd")
const Landscape = preload("res://scripts/landscape_events.gd")
const Save = preload("res://scripts/world_save.gd")
const Contract = preload("res://scripts/world_impact_contract.gd")
const Aftermath = preload("res://scripts/world_aftermath.gd")
const Atmosphere = preload("res://scripts/weather_atmosphere_controller.gd")
const NatureRenderer = preload("res://scripts/nature_renderer.gd")
const NatureCollision = preload("res://scripts/nature_collision.gd")

const SEEDS := [1729, 2411, 7291]
const DAYS := 96
const CHECKPOINT_DAYS := 12
const GEOLOGICAL_DAYS := [13, 37, 61, 85]
const AUDIT_PATH := "res://tests/world-stage-11-10-audit.json"

var failures: Array[String] = []
var scenarios: Array[Dictionary] = []


func _check(condition: bool, reason: String) -> void:
	# Не прерываем проверку из-за первой ошибки. Это даёт полный
	# перечень нарушенных физических подсистем в одном CI-логе.
	if not condition and failures.size() < 80:
		failures.append(reason)


func _models(seed: int) -> Dictionary:
	# Стартуем с настоящей процедурной картой; снег, реки и деревья
	# не задаём вручную, чтобы обнаружить реальные взаимодействия.
	var world := Map.new(Config.new(64, 48, seed, 16, 32))
	var hydro := Hydro.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	var climate := Climate.new(world, hydro)
	climate.rebuild()
	_check(climate.set_day(1), "Климат дня 1 создан: seed %d" % seed)
	_check(surface.advance_climate_day(climate),
		"Слой почвы дня 1 создан: seed %d" % seed)
	hydro.apply_rainfall_map(surface.runoff_map())
	var nature := Nature.new(world, hydro, surface, climate)
	_check(nature.generate(), "Растительность создана: seed %d" % seed)
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


func _save(state: Dictionary, context: String) -> Dictionary:
	# Атомарный снимок проверяет согласованность дня, ревизии
	# рельефа, водосбора, почвы, погоды, огня и природных ресурсов.
	var snapshot: Dictionary = Save.capture(state)
	_check(not snapshot.is_empty(), "Полный WorldSave: " + context)
	return snapshot


func _restore(state: Dictionary, context: String) -> Dictionary:
	# JSON проходит тот же декодер, что файл игры, включая полные
	# физические массивы; два расчёта после загрузки сравниваем позже.
	var snapshot: Dictionary = _save(state, context)
	if snapshot.is_empty():
		return {}
	var data: Variant = JSON.parse_string(JSON.stringify(snapshot))
	_check(data is Dictionary, "JSON снимка декодирован: " + context)
	if not (data is Dictionary):
		return {}
	var restored: Dictionary = Save.restore(data)
	_check(not restored.is_empty(), "Полная загрузка JSON: " + context)
	return restored


func _same_physics(a: Dictionary, b: Dictionary, context: String) -> void:
	# Сверяем исходную геометрию, водосбор, климат, грунт,
	# конечную древесину, пожары и истории событий. Никаких
	# сравнений GPU-цветов вместо физического состояния.
	_check(a["world"].to_data() == b["world"].to_data(),
		"Высоты и ревизия WorldMap: " + context)
	_check(a["hydro"].to_snapshot() == b["hydro"].to_snapshot(),
		"Гидрология/паводки: " + context)
	_check(a["surface"].to_snapshot() == b["surface"].to_snapshot(),
		"Снег, влага, плодородие и наносы: " + context)
	_check(a["climate"].to_data() == b["climate"].to_data(),
		"Сезоны и температура: " + context)
	_check(a["nature"].to_data() == b["nature"].to_data(),
		"Деревья, кустарники, упавшая древесина: " + context)
	_check(a["fire"].to_data() == b["fire"].to_data(),
		"Ожог, зола, уголь, активные очаги: " + context)
	_check(a["natural"].to_data() == b["natural"].to_data(),
		"Медленная эрозия: " + context)
	_check(a["disasters"].to_data() == b["disasters"].to_data(),
		"Накопленный риск бедствий: " + context)
	_check(a["weather"].to_snapshot() == b["weather"].to_snapshot(),
		"Молнии и история гроз: " + context)


func _contract(state: Dictionary, seed: int) -> void:
	# Любое неподтверждённое или недопустимое воздействие должно
	# оставить грунт, высоту, природные ресурсы и воду неизменными.
	var cell := Vector2i(28, 22)
	var invalid: Array[Dictionary] = [
		{"kind": "чёрная дыра", "cell": cell,
			"vertices": 200, "severity": 0.95},
		{"kind": "обвал", "cell": cell,
			"vertices": 0, "severity": 0.95},
		{"kind": "оползень", "cell": cell,
			"vertices": 25, "severity": NAN},
		{"kind": "землетрясение", "cell": cell,
			"vertices": 30, "severity": 1.4},
		{"kind": "оползень", "cell": cell,
			"vertices": -2, "severity": 0.9},
		{"kind": "оползень", "cell": cell,
			"vertices": 33.5, "severity": 0.9},
		{"kind": "кратер", "cell": cell,
			"vertices": 50, "severity": 0.8},
		{"kind": "обвал", "cell": Vector2i(-1, 9),
			"vertices": 50, "severity": 0.8}
	]
	var before: Dictionary = _save(state, "перед отказом %d" % seed)
	for event in invalid:
		_check(Contract.natural_deformation(event).is_empty() or
			not state["world"].config.contains_cell(event["cell"]),
			"Входной геологический контракт отвергает ложное воздействие")
	_check(Runner.register_geological_aftermath(state["surface"], invalid) == 0,
		"Ложные события не создают почвенное повреждение")
	_check(_save(state, "после отказа %d" % seed) == before,
		"Отклонённый удар атомарно сохранил все ресурсы")
	var valid: Dictionary = Contract.confirmed({
		"kind": "кратер", "cell": cell,
		"vertices": 50, "severity": 0.8
	})
	_check(not valid.is_empty() and float(valid["radius"]) == 5.0,
		"Подтверждённый кратер поддерживается общим контрактом")


func _manual_geology(state: Dictionary, day: int) -> void:
	# Сильный кратер и локальная просадка меняют настоящие
	# вершины. WorldDayRunner синхронизирует воду, снег и почву
	# до регистрации нового следа; второй массив высот запрещён.
	var kind := "кратер" if day == 13 or day == 61 else "просадка"
	var center := Vector2(28.5, 22.5) if day < 61 else Vector2(37.5, 26.5)
	var radius := 6.0 if kind == "кратер" else 5.0
	var strength := 1.2 if kind == "кратер" else 0.25
	var result: Dictionary = Landscape.new(state["world"]).apply(
		kind, center, radius, strength)
	_check(not result.is_empty(),
		"Сильная геология действительно изменила вершины, день %d" % day)
	if result.is_empty():
		return
	var event: Dictionary = Contract.confirmed({
		"kind": kind,
		"cell": state["world"].config.cell_at(center),
		"vertices": result["vertices"], "severity": 0.88
	})
	_check(not event.is_empty(),
		"Результат деформации соответствует общему контракту")
	_check(state["runner"].synchronize_world(),
		"После деформации пересчитаны водосбор и почва, день %d" % day)
	state["nature"].apply_landscape_impact(
		kind, center, radius, 0.88, day - 1)
	_check(state["surface"].register_geological_scar(
		kind, center, radius, 0.88),
		"Геологическое повреждение зарегистрировано в Surface")


func _trigger(runner: RefCounted, day: int) -> String:
	# Диагностическое событие проходит исключительно через реальную
	# суточную физику. Это не второй генератор стихий и не частицы.
	var target := Vector2i(29, 22)
	match day:
		5, 53:
			runner.test_storm_cell = target
			return "шторм"
		29:
			runner.test_hurricane_cell = target
			return "ураган"
		77:
			runner.test_tornado_cell = target
			return "смерч"
		41:
			runner.test_squall_cell = target
			return "шквал"
		17, 65:
			runner.test_fire_cell = target
	return ""


func _visual_probe(state: Dictionary, atmosphere: Node3D,
		day: int, seed: int) -> void:
	# Физический снимок фиксируем перед сменой камеры/качества.
	# Измеряем отсутствие дополнительных игровых событий, а не
	# равенство пикселей при разных графических пресетах.
	var before: Dictionary = _save(state,
		"до смены графики, seed %d день %d" % [seed, day])
	var center := Vector2(30.5, 23.5)
	var appearances := [0.15, 0.65, 1.0]
	for quality in range(3):
		atmosphere.set_quality(quality)
		for index in range(3):
			var zoom: float = [101.0, 75.0, 38.0][index]
			# Осадки/молнии читают только уже рассчитанные сутки.
			atmosphere.sync_world(state["climate"],
				state["world"], center, zoom)
			atmosphere.show_lightning(
				state["runner"].last_result.get("strikes", []),
				state["world"], center, zoom, day)
			var nature_chunk: Node3D = NatureRenderer.create_chunk(
				state["world"], state["nature"], Vector2i(1, 1),
				float(appearances[index]), state["fire"])
			_check(nature_chunk.get_child_count() <= 40,
				"GPU-природа использует ограниченные MultiMesh-группы")
			nature_chunk.free()
			# Физические коллизии строятся из того же NatureRegistry;
			# дальняя камера может их скрыть, но не изменить реестр.
			var collision: StaticBody3D = NatureCollision.create_chunk(
				state["world"], state["nature"], Vector2i(1, 1))
			_check(collision.get_child_count() <= state["nature"].count() * 2,
				"Формы не дублируют физические объекты")
			collision.free()
			var cell := Vector2i(29, 22)
			var combined: Dictionary = Aftermath.at(cell,
				state["world"], state["surface"], state["nature"],
				state["fire"], state["hydro"])
			_check(not combined.is_empty(),
				"Следы доступны при любом масштабе")
	# Пауза и загрузка очищают только кадры, не историю гроз
	# и не почвенный ожог. Это проверяет независимость от камеры.
	atmosphere.set_effects_enabled(false)
	atmosphere.clear_after_load(day)
	atmosphere.set_effects_enabled(true)
	_check(_save(state,
		"после смены графики, seed %d день %d" % [seed, day]) == before,
		"Рендер, коллизии и повторный вход не изменяют WorldSave")


func _audit_seed(seed: int, atmosphere: Node3D) -> Dictionary:
	# Два расчёта с одинаковым seed идут независимо. После каждого
	# сезона второй мир восстанавливается через штатный JSON/файл,
	# поэтому расхождения RNG и зависимость от FPS становятся видны.
	var state: Dictionary = _models(seed)
	_contract(state, seed)
	var peer: Dictionary = _restore(state, "начало seed %d" % seed)
	if peer.is_empty():
		return {}
	_same_physics(state, peer, "старт seed %d" % seed)

	var hazards := 0
	var strikes := 0
	var fires := 0
	var windfalls := 0
	var geology := 0
	var checkpoints := 0
	var peak_cpu_us := 0
	var total_cpu_us := 0
	for day in range(2, DAYS + 2):
		# Плановые воздействия попадают в уже физически активный
		# мир; двойник получает те же команды, не копию результата.
		if GEOLOGICAL_DAYS.has(day):
			_manual_geology(state, day)
			_manual_geology(peer, day)
			geology += 1
		var requested: String = _trigger(state["runner"], day)
		_trigger(peer["runner"], day)
		state["runner"].run_day()
		peer["runner"].run_day()
		var original: Dictionary = state["runner"].last_result
		var replay: Dictionary = peer["runner"].last_result
		_check(original == replay,
			"Единые физические события после загрузки: seed %d день %d" %
			[seed, day])
		_check(int(original.get("day", -1)) == day,
			"Суточный Runner не пропускает день %d" % day)
		if not requested.is_empty():
			# Источник «диагностика» должен возникнуть только один
			# раз; на следующих сутках тестовый запрос уже очищен.
			var matches := 0
			for event in original.get("hazards", []):
				if event.get("source") == "диагностика" and \
						event.get("kind") == requested:
					matches += 1
			_check(matches == 1,
				"Запрошенное бедствие возникло ровно однажды: %s" %
				requested)
		elif day not in [17, 65]:
			for event in original.get("hazards", []):
				_check(event.get("source") != "диагностика",
					"Диагностика не повторяется на следующих сутках")
		hazards += original.get("hazards", []).size()
		strikes += original.get("strikes", []).size()
		fires += original.get("fire_events", []).size()
		windfalls += original.get("windfalls", []).size()
		var cpu: int = state["runner"].last_duration_us
		total_cpu_us += cpu
		peak_cpu_us = maxi(peak_cpu_us, cpu)

		# Суточные физические значения ограничены независимо
		# от разрешения камеры. Деревья и зола не уходят в минус.
		_check(state["climate"].day == state["surface"].day
			and state["fire"].last_day == day
			and state["nature"].last_day == day,
			"Климат, почва, лес и огонь живут в одном дне")
		_check(state["nature"].wood_total() >= 0
			and state["fire"].ash_mass_total() >= 0
			and state["fire"].suspended_ash_total() >= 0,
			"Конечные древесина и зола не становятся отрицательными")
		_check(is_finite(state["surface"].sediment_balance()),
			"Наносы остаются конечными")

		if day % CHECKPOINT_DAYS != 1:
			continue
		var tag := "seed %d день %d" % [seed, day]
		_same_physics(state, peer, tag)
		var snapshot: Dictionary = _save(state, tag)
		if snapshot.is_empty():
			continue
		# В каждом втором чекпойнте проверяем реальную атомарную
		# запись файла с checksum, не только память и JSON.
		if day % 24 == 1:
			var path := "user://stage-11-10-audit-%d.json" % seed
			_check(Save.write_file(state, path),
				"Файл с контрольной суммой записан: " + tag)
			var disk: Dictionary = Save.read_file(path)
			_check(not disk.is_empty(),
				"Файл прочитан с проверкой контрольной суммы: " + tag)
			if not disk.is_empty():
				_same_physics(state, disk, "файл " + tag)
			_visual_probe(state, atmosphere, day, seed)
		peer = _restore(state, "перезапуск " + tag)
		if peer.is_empty():
			break
		_same_physics(state, peer, "после перезапуска " + tag)
		checkpoints += 1

	_check(state["climate"].day == DAYS + 1,
		"Симуляция прошла ровно %d суток" % DAYS)
	_same_physics(state, peer, "итог seed %d" % seed)
	_check(geology == GEOLOGICAL_DAYS.size() and checkpoints >= 7,
		"Четыре геологических удара и семь полных проверок на seed")
	return {
		"seed": seed,
		"start_day": 1,
		"end_day": state["climate"].day,
		"days": DAYS,
		"geological_events_applied": geology,
		"hazards_seen": hazards,
		"lightning_strikes_seen": strikes,
		"fire_events_seen": fires,
		"windfalls_seen": windfalls,
		"save_checkpoints": checkpoints,
		"world_revision": state["world"].revision,
		"water_rebuilds": state["hydro"].full_rebuilds,
		"nature_objects": state["nature"].count(),
		"wood_units": state["nature"].wood_total(),
		"ash_units": state["fire"].ash_mass_total(),
		"headless_cpu_day_us_total": total_cpu_us,
		"headless_cpu_day_us_peak": peak_cpu_us
	}


func _run() -> void:
	# Графический контроллер один на все сценарии: таким образом
	# проверяем и отсутствие размножения узлов между сезонами.
	var atmosphere := Atmosphere.new()
	root.add_child(atmosphere)
	for seed in SEEDS:
		var scenario: Dictionary = _audit_seed(seed, atmosphere)
		if not scenario.is_empty():
			scenarios.append(scenario)
	root.remove_child(atmosphere)
	atmosphere.free()

	var report := {
		"schema_version": 1,
		"stage": "11.10",
		"engine": Engine.get_version_info().get("string", "unknown"),
		"platform": OS.get_name(),
		"display_server": DisplayServer.get_name(),
		"hardware_fps_measured": false,
		"seeds": SEEDS,
		"days_per_seed": DAYS,
		"total_simulation_days": DAYS * scenarios.size(),
		"scenarios": scenarios,
		"failures": failures,
		"passed": failures.is_empty() and scenarios.size() == SEEDS.size()
	}
	# Артефакт записывается в GitHub Actions и доступен автору
	# с телефона. Это данные CI, не поддельный тест ПК/Android.
	var file := FileAccess.open(AUDIT_PATH, FileAccess.WRITE)
	_check(file != null, "Машинный отчёт аудита создан")
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()
	if not failures.is_empty():
		for failure in failures:
			push_error("11.10: " + failure)
		quit(1)
		return
	_check(scenarios.size() == SEEDS.size(), "Все три seed проверены")
	if not failures.is_empty():
		quit(1)
		return
	print("11.10: 3 seed × 96 дней, комбинированные события, JSON и графика — успешно.")
	quit(0)


func _initialize() -> void:
	call_deferred("_run")
