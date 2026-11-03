extends SceneTree
## Этап 6.3: отложения, берег, локальная перестройка и совместимость сохранений.

const Config = preload("res://scripts/world_config.gd")
const WorldMap = preload("res://scripts/world_map.gd")
const Hydrology = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Processes = preload("res://scripts/natural_processes.gd")
const Chunk = preload("res://scripts/chunk.gd")

var failures: Array[String] = []


func _check(condition: bool, description: String) -> void:
	if not condition:
		failures.append(description)


func _initialize() -> void:
	_run()


func _run() -> void:
	var world := WorldMap.new(Config.new(48, 32, 1729, 16, 32))
	# Создаём связное море и плавный берег без случайных типов клетки.
	var coast := {}
	for y in range(world.config.height + 1):
		for x in range(25):
			var elevation := -2.0
			if x == 13:
				elevation = -0.5
			elif x >= 14:
				elevation = 0.3 + float(x - 14) * 0.1
			coast[Vector2i(x, y)] = elevation
	_check(world.apply_vertex_changes(coast), "Физический берег создаётся пакетом")
	world.take_dirty_chunks()
	var hydro := Hydrology.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	var climate := Climate.new(world, hydro)
	climate.rebuild()
	climate.set_day(1)
	var processes := Processes.new(world, hydro, surface, climate)
	var shore := Vector2i(14, 16)
	var sea := Vector2i(13, 16)
	_check(hydro.ocean_at(hydro.cell_index(sea)), "Море связано с границей карты")
	_check(not hydro.ocean_at(hydro.cell_index(shore)), "Берег остаётся сушей")
	var risk: Dictionary = processes.estimate_at(shore)
	_check(float(risk.get("coast", 0.0)) > 0.01,
		"Морской берег получает риск размыва от ветра и породы")
	_check(risk.get("coast_target", Vector2i(-1, -1)) == sea,
		"Береговой перенос направлен в реальную морскую клетку")
	var source_before: float = world.vertex_at(shore)
	var sea_before: float = world.vertex_at(sea)
	var old_revision: int = world.revision
	_check(not surface.transfer_sediment(shore, sea, INF)
		and not surface.transfer_sediment(shore, sea, -0.01)
		and not surface.transfer_sediment(shore, shore, 0.01),
		"Некорректный объём и направление не меняют геологию")
	_check(world.revision == old_revision,
		"Ошибочные переносы не оставляют частичных изменений")

	# За пределами изменённого чанка снег и геология сохраняются.
	var far := Vector2i(40, 8)
	surface.advance_day(1.2, -13.0)
	var far_profile: Dictionary = surface.profile_at(far)
	_check(surface.transfer_sediment(shore, sea, 0.01),
		"Береговая эрозия перемещает настоящий материал")
	_check(world.revision == old_revision + 1,
		"Два изменения вершин регистрируются одной транзакцией")
	_check(absf(world.vertex_at(shore) - (source_before - 0.01)) < 0.00001
		and absf(world.vertex_at(sea) - (sea_before + 0.01)) < 0.00001,
		"Объём убывает на берегу и накапливается на морском дне")
	_check(absf(surface.sediment_balance()) < 0.00001,
		"В балансе не появляется и не исчезает нанос")
	_check(absf(float(surface.profile_at(shore)["sediment"]) + 0.01) < 0.00001
		and absf(float(surface.profile_at(sea)["sediment"]) - 0.01) < 0.00001,
		"Происхождение наносов фиксируется отдельно от высот")
	_check(surface.profile_at(far)["snow"] == far_profile["snow"]
		and surface.profile_at(far)["depth"] == far_profile["depth"],
		"Локальный пересчёт сохраняет удалённые снега и почвы")

	var saved_world: Dictionary = JSON.parse_string(JSON.stringify(world.to_data()))
	var saved_surface: Dictionary = JSON.parse_string(JSON.stringify(surface.to_data()))
	var restored_world := WorldMap.from_data(saved_world)
	_check(restored_world != null, "Изменённая береговая линия восстанавливается")
	if restored_world != null:
		var restored_hydro := Hydrology.new(restored_world)
		restored_hydro.rebuild()
		var restored_surface := Surface.new(restored_world, restored_hydro)
		restored_surface.rebuild()
		_check(restored_surface.load_data(saved_surface),
			"Слой наносов восстанавливается вместе с картой")
		_check(absf(float(restored_surface.profile_at(sea)["sediment"])
			- 0.01) < 0.00001, "После загрузки сохраняются нанесённые отложения")
		_check(restored_surface.sediment_color_at(sea)
			!= restored_surface.sediment_color_at(shore),
			"Накопление и размыв различимы на GPU")
		var view := Chunk.create_mesh(0, 1, 1, restored_world,
			restored_surface, 6)
		_check(view.get_surface_count() == 1,
			"Есть отдельный GPU-слой распределения наносов")
		var older := saved_surface.duplicate(true)
		older["version"] = 2
		older.erase("sediment_changes")
		_check(restored_surface.load_data(older),
			"Сохранения грунтов версии 2 остаются читаемыми")
		_check(absf(restored_surface.sediment_balance()) < 0.00001,
			"Старые сохранения не создают фиктивных наносов")
		var bad := saved_surface.duplicate(true)
		bad["sediment_changes"] = [[999999, 10000]]
		_check(not restored_surface.load_data(bad),
			"Невозможный индекс отложения отвергается")
		bad["sediment_changes"] = [[5, 10000], [5, 10000]]
		_check(not restored_surface.load_data(bad),
			"Повторный индекс в сохранении запрещён")

	if not failures.is_empty():
		for reason in failures:
			push_error("Этап 6.3: " + reason)
		quit(1)
		return
	print("Этап 6.3: берег, перенос наносов, локальные чанки и сохранение — успешно.")
	quit(0)
