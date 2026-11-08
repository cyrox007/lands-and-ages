extends RefCounted
## Видовые точки для первой демонстрации живого природного мира.
## Места берутся из действительных гор, рек, деревьев и побережья.
## Поиск не изменяет физические реестры и не создаёт декораций.

const WaterMesh = preload("res://scripts/water_mesh.gd")


static func select_views(world: RefCounted, hydro: RefCounted,
		surface: RefCounted, nature: RefCounted) -> Array[Dictionary]:
	# Однократный поиск выполняется только при открытии маршрута.
	# Избегаем заданных вручную координат: другой seed или размер
	# карты должен привести игрока к реально существующим местам.
	var size := Vector2i(world.config.width, world.config.height)
	var middle := Vector2(size) * 0.5
	var mountain := Vector2i(-1, -1)
	var bend := Vector2i(-1, -1)
	var coast := Vector2i(-1, -1)
	var highest := -INF
	var best_turn := -1.0
	var coast_distance := INF
	var margin := mini(12, mini(size.x, size.y) / 5)
	for y in range(margin, size.y - margin):
		for x in range(margin, size.x - margin):
			var cell := Vector2i(x, y)
			var index: int = hydro.cell_index(cell)
			if hydro.has_water(index):
				# Речное русло ищем по физическому графу стока.
				# Сравнение направлений не меняет сам поток воды.
				if hydro.river_at(index):
					var next: int = hydro.downstream_of(index)
					if next >= 0 and hydro.river_at(next):
						var first: Dictionary = WaterMesh._river_frame(
							world, hydro, cell)
						var second: Dictionary = WaterMesh._river_frame(
							world, hydro, hydro.cell_from_index(next))
						if not first.is_empty() and not second.is_empty():
							var curvature := 1.0 - clampf(
								first["direction"].dot(second["direction"]),
								-1.0, 1.0)
							if curvature > best_turn:
								best_turn = curvature
								bend = cell
				continue
			# Выбираем настоящий высокий скалистый хребет,
			# исключая приграничную рамку мирового генератора.
			var score: float = world.vertex_at(cell)
			if surface.rock_at_index(index):
				score += 6.0
			if score > highest:
				highest = score
				mountain = cell
			# Побережье выбираем на суше у океана, чтобы точка
			# камеры не оказалась посреди морской поверхности.
			for offset in [Vector2i(1, 0), Vector2i(-1, 0),
					Vector2i(0, 1), Vector2i(0, -1)]:
				if not hydro.ocean_at(hydro.cell_index(cell + offset)):
					continue
				var distance := Vector2(cell).distance_squared_to(middle)
				if distance < coast_distance:
					coast_distance = distance
					coast = cell
				break
	var forest := _find_forest(world, nature)
	var scenes: Array[Dictionary] = []
	if forest.x >= 0:
		scenes.append({
			"name": "Лесная долина", "cell": forest, "zoom": 38.0,
			"meaning": "Настоящие деревья и природный покров"
		})
	if bend.x >= 0:
		scenes.append({
			"name": "Изгиб реки", "cell": bend, "zoom": 30.0,
			"meaning": "Реальное русло и соседние берега"
		})
	if mountain.x >= 0:
		scenes.append({
			"name": "Горный хребет", "cell": mountain, "zoom": 52.0,
			"meaning": "Физические вершины, скалы и предгорья"
		})
	if coast.x >= 0:
		scenes.append({
			"name": "Морской берег", "cell": coast, "zoom": 40.0,
			"meaning": "Переход суши в настоящий океан"
		})
	return scenes


static func _find_forest(world: RefCounted,
		nature: RefCounted) -> Vector2i:
	# Считаем реальные живые деревья по чанкам и выбираем
	# самый населённый лесом участок. Не храним второй лесной
	# реестр и не заставляем каждый кадр обходить деревья.
	var chunks: Vector2i = world.config.chunk_count()
	var best_count := 0
	var best_cell := Vector2i(-1, -1)
	var middle := Vector2(world.config.width, world.config.height) * 0.5
	var best_distance := INF
	for cy in range(chunks.y):
		for cx in range(chunks.x):
			var trees := 0
			var sum := Vector2.ZERO
			for item in nature.objects_in_chunk(Vector2i(cx, cy)):
				if item["kind"] != "дерево" or item["state"] != "целое":
					continue
				trees += 1
				sum += Vector2(float(item["x"]), float(item["y"]))
			if trees <= 0:
				continue
			var center := sum / float(trees)
			var distance := center.distance_squared_to(middle)
			# При одинаковой плотности предпочитаем ближний лес:
			# это удобнее для естественного продолжения маршрута.
			if trees < best_count or (trees == best_count
					and distance >= best_distance):
				continue
			best_count = trees
			best_distance = distance
			best_cell = Vector2i(roundi(center.x), roundi(center.y))
	return best_cell
