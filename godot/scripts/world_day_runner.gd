extends RefCounted
## Суточная физика мира. Не обращается к сцене, камере и GPU.
## При работе в потоке главный поток не читает физические модели.

var world: RefCounted
var hydro: RefCounted
var surface: RefCounted
var climate: RefCounted
var weather_events: RefCounted
var natural_processes: RefCounted
var natural_disasters: RefCounted
var nature: RefCounted
var fire: RefCounted

var last_result: Dictionary = {}
var last_profile_us: Dictionary = {}
var last_statistics: Dictionary = {}
var last_duration_us := 0
# Явный тестовый шторм задаётся из диагностического UI ДО запуска
# фоновой задачи, и сбрасывается в первом же расчётном дне.
var test_storm_cell := Vector2i(-1, -1)
var test_squall_cell := Vector2i(-1, -1)
var test_hurricane_cell := Vector2i(-1, -1)
var test_shrub_cell := Vector2i(-1, -1)
var test_fire_cell := Vector2i(-1, -1)
var test_tornado_cell := Vector2i(-1, -1)
var test_dust_cell := Vector2i(-1, -1)


func _init(map: RefCounted, water: RefCounted, ground: RefCounted,
		weather: RefCounted, lightning: RefCounted, erosion: RefCounted,
		disasters: RefCounted, vegetation: RefCounted = null,
		fires: RefCounted = null) -> void:
	world = map
	hydro = water
	surface = ground
	climate = weather
	weather_events = lightning
	natural_processes = erosion
	natural_disasters = disasters
	nature = vegetation
	fire = fires
	# Одна и та же сохранённая зола должна влиять на перенос грунта
	# в игре, тестах и загруженных мирах. Старые тесты без огня
	# по-прежнему используют нейтральный коэффициент.
	if natural_processes != null:
		natural_processes.fire = fire


func synchronize_world() -> bool:
	# Водосборы могут меняться далеко от деформированной вершины.
	# Приводим все взаимозависимые модели к одной ревизии.
	var chunks: Array[Vector2i] = world.take_dirty_chunks()
	if chunks.is_empty():
		return false
	hydro.ensure_ready()
	for chunk in hydro.take_changed_water_chunks():
		if not chunks.has(chunk):
			chunks.append(chunk)
	climate.rebuild_if_stale(chunks)
	surface.rebuild(chunks)
	surface.synchronize_climate(climate, climate.last_updated_rows)
	return true


static func nature_hazards(hazards: Array[Dictionary],
		erosion: Dictionary) -> Array[Dictionary]:
	# Стихийный реестр хранит свои события независимо от медленных
	# геологических процессов. Для леса объединяем только воздействия,
	# которые действительно передвинули вершины WorldMap.
	# Обычные наносы и неудавшиеся оползни не наносят вымышленный урон.
	var result: Array[Dictionary] = []
	result.append_array(hazards)
	if erosion.get("kind") != "оползень" \
			or erosion.get("process") != "slide" \
			or int(erosion.get("vertices", 0)) <= 0 \
			or not (erosion.get("cell") is Vector2i):
		return result
	var severity: float = float(erosion.get("severity", 0.0))
	if not is_finite(severity) or severity <= 0.0 or severity > 1.0:
		return result
	result.append({
		"kind": "оползень", "cell": erosion["cell"],
		"vertices": int(erosion["vertices"]),
		"severity": severity, "day": int(erosion.get("day", 0))
	})
	return result


func run_day() -> void:
	# Метод исполняется WorkerThreadPool, пока GPU читает лишь старые
	# готовые меши. Сцену и её узлы здесь не трогаем.
	var start := Time.get_ticks_usec()
	var before_rebuilds: int = hydro.full_rebuilds
	var before_ground_cells: int = hydro.total_ground_cells
	var previous := start
	climate.set_day(climate.day + 1)
	var climate_us := Time.get_ticks_usec() - previous
	previous = Time.get_ticks_usec()
	surface.advance_climate_day(climate)
	var surface_us := Time.get_ticks_usec() - previous
	previous = Time.get_ticks_usec()
	hydro.apply_rainfall_map(surface.runoff_map())
	var hydro_us := Time.get_ticks_usec() - previous
	previous = Time.get_ticks_usec()
	var strikes: Array[Dictionary] = weather_events.advance_day(climate.day)
	var lightning_us := Time.get_ticks_usec() - previous
	previous = Time.get_ticks_usec()
	var erosion: Dictionary = natural_processes.advance_day(climate.day)
	var erosion_us := Time.get_ticks_usec() - previous
	previous = Time.get_ticks_usec()
	var hazards: Array[Dictionary] = natural_disasters.advance_day(climate.day)
	var dust_test_failed := false
	if world.config.contains_cell(test_storm_cell):
		# Это явно запрошенное испытание, а не естественный погодный
		# фронт. Урон и ресурсы обрабатывает обычный NatureRegistry.
		hazards.append({
			"kind": "шторм", "cell": test_storm_cell,
			"severity": 1.0, "day": climate.day,
			"source": "диагностика"
		})
	test_storm_cell = Vector2i(-1, -1)
	if world.config.contains_cell(test_squall_cell):
		# Испытание проводит настоящий локальный шквал тем же путём,
		# что и случайные бедствия. Частицы не создают урон напрямую.
		hazards.append({
			"kind": "шквал", "cell": test_squall_cell,
			"severity": 1.0, "day": climate.day,
			"source": "диагностика", "duration_days": 1
		})
	test_squall_cell = Vector2i(-1, -1)
	if world.config.contains_cell(test_hurricane_cell):
		# Испытание не переписывает климат и не выдаёт шторм за ураган:
		# тот же физический обработчик, что и для естественного события.
		hazards.append({
			"kind": "ураган", "cell": test_hurricane_cell,
			"severity": 1.0, "day": climate.day,
			"source": "диагностика", "duration_days": 1
		})
	test_hurricane_cell = Vector2i(-1, -1)
	if world.config.contains_cell(test_shrub_cell):
		# Куст испытывается тем же ураганом, что и деревья:
		# здесь выбираем эпицентр, а не устанавливаем здоровье напрямую.
		hazards.append({
			"kind": "ураган", "cell": test_shrub_cell,
			"severity": 1.0, "day": climate.day,
			"source": "диагностика", "target": "кустарник",
			"duration_days": 1
		})
	test_shrub_cell = Vector2i(-1, -1)
	if world.config.contains_cell(test_tornado_cell):
		# Смерч тестируется через штатную обработку hazards. Команда
		# влияет только на выбор события следующего физического дня.
		hazards.append({
			"kind": "смерч", "cell": test_tornado_cell,
			"severity": 1.0, "day": climate.day,
			"source": "диагностика", "duration_days": 1
		})
	test_tornado_cell = Vector2i(-1, -1)
	if world.config.contains_cell(test_dust_cell):
		# Физика испытания использует тот же метод переноса грунта,
		# что и естественное бедствие, вместо декоративной подмены.
		var moved: Dictionary = natural_disasters.apply_dust_storm(
			test_dust_cell, 1.0)
		if moved.is_empty():
			# Если грунт намок или снег покрыл поверхность за сутки,
			# не изображаем фиктивное бедствие без переноса массы.
			dust_test_failed = true
		else:
			hazards.append({
				"kind": "пыльная буря", "cell": test_dust_cell,
				"severity": 1.0, "day": climate.day,
				"source": "диагностика", "duration_days": 1,
				"vertices": moved["vertices"],
				"sediment_volume": moved["sediment_volume"],
				"airborne_volume": moved.get("airborne_volume", 0.0)
			})
	test_dust_cell = Vector2i(-1, -1)
	var disasters_us := Time.get_ticks_usec() - previous
	previous = Time.get_ticks_usec()
	var changed := synchronize_world()
	var vegetation_us := 0
	if nature != null and nature.generated:
		var plants_started := Time.get_ticks_usec()
		# Тот же реестр почвенного ожога поступает в рост растений,
		# восстановление и геологические процессы.
		# Учитываем также медленные оползни NaturalProcesses.
		# Сами hazards остаются реестром NaturalDisasters, а лес
		# получает оба физически подтверждённых источника деформаций.
		nature.advance_day(climate.day,
			nature_hazards(hazards, erosion), strikes, fire)
		vegetation_us = Time.get_ticks_usec() - plants_started
	# После природного шага огонь изменяет те же физические объекты.
	# В старых тестовых сценариях без FireRegistry поле остаётся null.
	var fire_events: Array[Dictionary] = []
	var fire_started := Time.get_ticks_usec()
	if fire != null and nature != null and nature.generated:
		fire_events = fire.advance_day(climate.day, strikes, test_fire_cell)
	test_fire_cell = Vector2i(-1, -1)
	var fire_us := Time.get_ticks_usec() - fire_started
	var synchronization_us := Time.get_ticks_usec() - previous
	last_duration_us = Time.get_ticks_usec() - start
	last_statistics = {
		"пересчёты водосборов": hydro.full_rebuilds - before_rebuilds,
		"прочитано высот": hydro.total_ground_cells - before_ground_cells
	}
	last_profile_us = {
		"климат": climate_us,
		"почва": surface_us,
		"гидрология": hydro_us,
		"молнии": lightning_us,
		"эрозия": erosion_us,
		"бедствия": disasters_us,
		"растительность": vegetation_us,
		"горение": fire_us,
		"согласование": synchronization_us
	}
	last_result = {
		"day": climate.day,
		"strikes": strikes,
		"erosion": erosion,
		"hazards": hazards,
		"dust_test_failed": dust_test_failed,
		"fire_events": fire_events,
		"fires_active": fire.burning_count() if fire != null else 0,
		"windfalls": nature.last_windfalls.duplicate(true)
			if nature != null and nature.generated else [],
		"terrain_changed": changed
	}
