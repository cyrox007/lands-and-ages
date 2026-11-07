extends RefCounted
## Сводный физический срез постоянных последствий на одной клетке.
## Источники не копируются и не сохраняются повторно: WorldMap,
## Surface, FireRegistry и NatureRegistry остаются владельцами данных.


static func at(cell: Vector2i, world: RefCounted,
		surface: RefCounted, nature: RefCounted,
		fire: RefCounted, hydro: RefCounted) -> Dictionary:
	# Не проверяем весь мир и не создаём реестр эффектов: чтение
	# одной клетки годится и для диагностики, и для приёмки после
	# перемещения камеры. Не создаём след у клетки вне карты.
	if not world.config.contains_cell(cell):
		return {}
	var index: int = hydro.cell_index(cell)
	if index < 0:
		return {}

	# Все почвенные поля берём из того же физического Surface,
	# которым пользуются рост растений, эрозия, снег и водосбор.
	var soil: Dictionary = surface.profile_at(cell,
		fire.soil_damage_at(cell) if fire != null else 0.0)
	var item: Dictionary = {}
	if nature != null and nature.generated:
		var object_id: int = cell.y * world.config.width + cell.x + 1
		item = nature.object_at(object_id)

	# Лежащая древесина принадлежит единственному объекту леса,
	# а зола, уголь и ожог — единственному реестру пожаров.
	# Следы сосуществуют, поэтому ни один из них не заменяет другой.
	return {
		"cell": cell,
		"day": surface.day,
		"geological_scar": float(soil["geological_scar"]),
		"fire_damage": float(soil["fire_damage"]),
		"scorched": fire.scorched_at(cell) if fire != null else 0.0,
		"charcoal": fire.charcoal_at(cell) if fire != null else 0,
		"suspended_ash": fire.suspended_ash_at(cell) if fire != null else 0,
		"snow": float(soil["snow"]),
		"sediment": float(soil["sediment"]),
		"waterlogging": float(soil["waterlogging"]),
		"fertility": float(soil["fertility"]),
		"fallen_wood": int(item.get("fallen_wood", 0)),
		"object_state": str(item.get("state", "нет объекта")),
		"surface_revision": surface.revision,
		"world_revision": world.revision
	}
