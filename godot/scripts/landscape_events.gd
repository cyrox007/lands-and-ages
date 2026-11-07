extends RefCounted
## Команды изменения рельефа: природные процессы и будущие стихийные события.
## Мир остаётся единственным владельцем высот; команда изменяет их атомарно.

signal event_applied(kind: String, bounds: Rect2i, revision: int)

const Map = preload("res://scripts/world_map.gd")
const MAX_VERTICES := 65000
const MIN_RADIUS := 2.0
const MAX_RADIUS := 144.0
const MAX_STRENGTH := 8.0

var world: RefCounted


func _init(map: RefCounted) -> void:
	world = map


static func _weight(distance: float, radius: float) -> float:
	var normalized := clampf(distance / radius, 0.0, 1.0)
	var smooth := 1.0 - smoothstep(0.0, 1.0, normalized)
	return smooth * smooth


func apply(kind: String, center: Vector2, radius: float, strength: float) -> Dictionary:
	# Применяется к вершинам, а не к произвольно выбранным типам клеток.
	if kind not in ["поднятие", "просадка", "эрозия", "оползень", "обвал", "кратер"]:
		return {}
	if not is_finite(center.x) or not is_finite(center.y):
		return {}
	if not world.config.contains_point(center):
		return {}
	if not is_finite(radius) or radius < MIN_RADIUS or radius > MAX_RADIUS:
		return {}
	if not is_finite(strength) or strength <= 0.0 or strength > MAX_STRENGTH:
		return {}

	var left := maxi(0, floori(center.x - radius))
	var right := mini(world.config.width, ceili(center.x + radius))
	var top := maxi(0, floori(center.y - radius))
	var bottom := mini(world.config.height, ceili(center.y + radius))
	var width := right - left + 1
	var height := bottom - top + 1
	if width * height > MAX_VERTICES:
		return {}

	var points: Array[Vector2i] = []
	var weights := PackedFloat32Array()
	for y in range(top, bottom + 1):
		for x in range(left, right + 1):
			var distance := Vector2(float(x), float(y)).distance_to(center)
			var weight := _weight(distance, radius)
			if weight <= 0.0:
				continue
			points.append(Vector2i(x, y))
			weights.append(weight)
	if points.is_empty():
		return {}

	var deltas := PackedFloat32Array()
	deltas.resize(points.size())
	if kind == "поднятие" or kind == "просадка":
		var direction_sign := 1.0 if kind == "поднятие" else -1.0
		for i in range(points.size()):
			deltas[i] = direction_sign * strength * weights[i]
	elif kind == "эрозия":
		_plan_erosion(points, weights, strength, deltas)
	elif kind == "оползень":
		if not _plan_landslide(center, radius, points, strength, deltas):
			return {}
	elif kind == "обвал":
		if not _plan_rockfall(center, radius, points, strength, deltas):
			return {}
	else:
		if not _plan_crater(center, radius, points, strength, deltas):
			return {}

	var changes := {}
	var modified := 0
	for i in range(points.size()):
		if absf(deltas[i]) < 0.000001:
			continue
		var before: float = world.vertex_at(points[i])
		var after := before + deltas[i]
		# Нельзя обрезать высоты по лимиту: это нарушит баланс грунта.
		if not is_finite(after) or after < Map.MIN_HEIGHT or after > Map.MAX_HEIGHT:
			return {}
		changes[points[i]] = after
		modified += 1
	if modified == 0 or not world.apply_vertex_changes(changes):
		return {}
	var bounds := Rect2i(Vector2i(left, top), Vector2i(width, height))
	event_applied.emit(kind, bounds, world.revision)
	return {
		"kind": kind, "bounds": bounds,
		"vertices": modified, "revision": world.revision
	}


func _plan_erosion(points: Array[Vector2i], weights: PackedFloat32Array,
		strength: float, deltas: PackedFloat32Array) -> void:
	# Сглаживание неровностей с локальным балансом снятого и нанесённого.
	var imbalance := 0.0
	var total_weight := 0.0
	for i in range(points.size()):
		var coord := points[i]
		var height: float = world.vertex_at(coord)
		var total := 0.0
		var neighbours := 0
		for offset in [Vector2i(-1, 0), Vector2i(1, 0),
				Vector2i(0, -1), Vector2i(0, 1)]:
			var near: Vector2i = coord + offset
			if not world.config.contains_vertex(near):
				continue
			total += world.vertex_at(near)
			neighbours += 1
		if neighbours == 0:
			continue
		deltas[i] = (total / float(neighbours) - height) \
			* strength * 0.12 * weights[i]
		imbalance += deltas[i]
		total_weight += weights[i]
	if total_weight <= 0.0:
		return
	for i in range(points.size()):
		deltas[i] -= imbalance * weights[i] / total_weight


func _plan_landslide(center: Vector2, radius: float,
		points: Array[Vector2i], strength: float,
		deltas: PackedFloat32Array) -> bool:
	# Грунт перемещается вниз по уклону: источник теряет объём,
	# область отложения получает его. Сумма изменений ≈ 0.
	var probe := Vector2i(roundi(center.x), roundi(center.y))
	var normal: Vector3 = world.normal_at(probe)
	var downhill := Vector2(normal.x, normal.z)
	if downhill.length() < 0.045:
		return false
	downhill = downhill.normalized()
	var source := center - downhill * radius * 0.24
	var target := center + downhill * radius * 0.24
	var source_weights := PackedFloat32Array()
	var target_weights := PackedFloat32Array()
	var source_sum := 0.0
	var target_sum := 0.0
	for coord in points:
		var at := Vector2(coord)
		var a := _weight(at.distance_to(source), radius * 0.63)
		var b := _weight(at.distance_to(target), radius * 0.63)
		source_weights.append(a)
		target_weights.append(b)
		source_sum += a
		target_sum += b
	if source_sum < 0.01 or target_sum < 0.01:
		return false
	var volume := strength * minf(source_sum, target_sum)
	for i in range(points.size()):
		deltas[i] = volume * (target_weights[i] / target_sum
			- source_weights[i] / source_sum)
	return true


func _plan_rockfall(center: Vector2, radius: float,
		points: Array[Vector2i], strength: float,
		deltas: PackedFloat32Array) -> bool:
	# Скальный обвал отличается от оползня: обрушение локализовано
	# в верхней части уступа, а каменная масса собирается у подножия.
	# Направление берём из физической нормали, а не из камеры.
	var probe := Vector2i(roundi(center.x), roundi(center.y))
	var normal: Vector3 = world.normal_at(probe)
	var downhill := Vector2(normal.x, normal.z)
	if downhill.length() < 0.16:
		return false
	downhill = downhill.normalized()
	var source := center - downhill * radius * 0.30
	var target := center + downhill * radius * 0.34
	# Возле границы нельзя терять часть осыпи за пределами карты.
	# Разность высот подтверждает реальный уклон до изменения рельефа.
	if not world.config.contains_point(source) or not world.config.contains_point(target):
		return false
	if world.height_at(source) - world.height_at(target) < 0.45:
		return false

	var upper_weights := PackedFloat32Array()
	var lower_weights := PackedFloat32Array()
	var upper_total := 0.0
	var lower_total := 0.0
	for point in points:
		var position := Vector2(point)
		var upper := _weight(position.distance_to(source), radius * 0.44)
		var lower := _weight(position.distance_to(target), radius * 0.47)
		upper_weights.append(upper)
		lower_weights.append(lower)
		upper_total += upper
		lower_total += lower
	if upper_total < 0.01 or lower_total < 0.01:
		return false

	# Снятый объём распределяем по зоне осыпи с той же суммой.
	# Это деформация каменной основы, а не создание рыхлого грунта
	# или отдельного ресурса в Surface.
	var volume := strength * minf(upper_total, lower_total)
	for i in range(points.size()):
		deltas[i] = volume * (lower_weights[i] / lower_total
			- upper_weights[i] / upper_total)
	return true


func _plan_crater(center: Vector2, radius: float,
		points: Array[Vector2i], strength: float,
		deltas: PackedFloat32Array) -> bool:
	# Кратер создаётся только явным мощным локальным воздействием.
	# Землетрясение само по себе не выдумывает ударный кратер.
	# Полный край нужен, чтобы выброшенная порода не исчезала
	# за пределами мира и оставалась в том же физическом слое.
	if radius < 3.0 or center.x - radius < 0.0 \\
			or center.y - radius < 0.0 \\
			or center.x + radius > float(world.config.width) \\
			or center.y + radius > float(world.config.height):
		return false

	var pit_weights := PackedFloat32Array()
	var rim_weights := PackedFloat32Array()
	var pit_total := 0.0
	var rim_total := 0.0
	for point in points:
		var distance := Vector2(point).distance_to(center) / radius
		# Глубина уменьшается к внутреннему склону; выброс образует
		# отдельный кольцевой вал, а не просто цветную текстуру.
		var pit := pow(1.0 - smoothstep(0.0, 0.63, distance), 2.0)
		var rim := pow(maxf(0.0, 1.0 - absf(distance - 0.79) / 0.21), 2.0)
		pit_weights.append(pit)
		rim_weights.append(rim)
		pit_total += pit
		rim_total += rim
	if pit_total < 0.01 or rim_total < 0.01:
		return false

	# Высоту впадины и вала рассчитываем единым атомарным пакетом.
	# Сумма снятой породы равна сумме отложенной до округления
	# вершин в WorldMap, в том числе после сохранения/загрузки.
	var ratio := pit_total / rim_total
	for i in range(points.size()):
		deltas[i] = strength * (rim_weights[i] * ratio - pit_weights[i])
	return true
