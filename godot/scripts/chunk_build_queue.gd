extends RefCounted
## Приоритетная очередь построения GPU-чанков.
## Сначала закрываем пробелы в кадре, затем обновляем старые меши.

static func prioritize(pending: Array[Vector2i], center: Vector2,
		motion: Vector2, chunk_size: int, active: Dictionary,
		required: Dictionary = {}) -> void:
	var direction := motion.normalized() if motion.length_squared() > 0.001 \
		else Vector2.ZERO
	# Небольшое смещение приоритета вперёд по направлению панорамы.
	var focus := center + direction * minf(float(chunk_size) * 0.65, 12.0)
	var distances := {}
	for coord in pending:
		distances[coord] = _distance_squared(coord, focus, chunk_size)
	pending.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if required.has(a) != required.has(b):
			return required.has(a)
		if active.has(a) != active.has(b):
			return not active.has(a)
		var priority_a: float = distances[a]
		var priority_b: float = distances[b]
		if not is_equal_approx(priority_a, priority_b):
			return priority_a < priority_b
		return a.y < b.y or (a.y == b.y and a.x < b.x))


static func _distance_squared(coord: Vector2i, center: Vector2,
		chunk_size: int) -> float:
	var chunk_center := Vector2(coord) * float(chunk_size) \
		+ Vector2.ONE * float(chunk_size) * 0.5
	return chunk_center.distance_squared_to(center)


static func budget_us(p95_ms: float, camera_moved: bool,
		normal_budget_us: int = 4200) -> int:
	# Замеры в headless CI не заменяют аппаратный FPS; лимиты осторожные.
	if camera_moved or p95_ms >= 26.0:
		return mini(normal_budget_us, 1400)
	if p95_ms >= 20.0:
		return mini(normal_budget_us, 2500)
	return normal_budget_us
