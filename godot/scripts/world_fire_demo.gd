extends RefCounted
## Сквозное испытание настоящего пожара из игровой сцены.
## Не содержит собственной физики: выбирает существующее горючее
## дерево и сверяет реальные модели после WorldSave.

const SAVE_PATH := "user://fire-demo-world.json"
const BEFORE_PNG := "user://fire-demo-before.png"
const AFTER_PNG := "user://fire-demo-after.png"
const RESTORED_PNG := "user://fire-demo-restored.png"


static func choose_tree(nature: RefCounted, fire: RefCounted,
		chunks: Array, center: Vector2) -> Dictionary:
	# Выбираем ближайшее пригодное дерево только среди уже
	# видимых чанков: пользователь увидит тот же физический объект,
	# что попадёт в FireRegistry на следующем дне.
	var selected := {}
	var best := INF
	for chunk in chunks:
		for item in nature.objects_in_chunk(chunk):
			if item.get("kind") != "дерево" or 					item.get("state") not in ["целое", "сухостой"]:
				continue
			var cell := Vector2i(int(item["x"]), int(item["y"]))
			# Принудительный тест не подменяет влажную землю сухой:
			# штатный FireRegistry тоже проверяет порог горючести.
			if fire._flammability(cell) < 0.25:
				continue
			var distance := (Vector2(cell) + Vector2(0.5, 0.5)) \
				.distance_squared_to(center)
			if distance >= best:
				continue
			best = distance
			selected = {"cell": cell, "id": int(item["id"])}
	return selected


static func ignition_confirmed(events: Array, cell: Vector2i) -> bool:
	# Надпись «Пожар начался» показываем только после реального
	# события реестра; декоративное пламя и тестовая команда сами
	# по себе не являются доказательством возгорания.
	for event in events:
		if str(event.get("kind", "")) != "возгорание":
			continue
		if event.get("cell") == cell:
			return true
	return false


static func physical_equal(a: Dictionary, b: Dictionary) -> bool:
	# Сравниваем все слои из настоящего WorldSave, включая природу,
	# горение, ресурсы и грунт. Служебные кадры и положение камеры
	# в модель не входят и не могут скрыть потери после загрузки.
	if a.is_empty() or b.is_empty():
		return false
	for key in ["version", "day", "world", "hydrology", "climate",
			"surface", "weather", "natural", "disasters", "nature", "fire"]:
		if not a.has(key) or not b.has(key) or a[key] != b[key]:
			return false
	return true


static func slowest_phase(profile: Dictionary) -> Dictionary:
	# Сумма отдельных фаз теперь не содержит двойного учёта,
	# поэтому можно честно показать самую затратную часть дня.
	var name := ""
	var duration := 0
	for key in profile:
		var elapsed := int(profile[key])
		if elapsed <= duration:
			continue
		name = str(key)
		duration = elapsed
	return {"name": name, "us": duration}
