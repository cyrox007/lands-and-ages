extends RefCounted
## Проверка видимости чанка в прямоугольнике ортографической камеры.
## В расчёте используются только границы GPU-меша, не законы мира.

static func intersects(bounds: Rect2i, elevation: Vector2,
		camera_position: Vector3, right: Vector3, up: Vector3,
		vertical_size: float, aspect: float, padding: float = 1.5) -> bool:
	if not bounds.has_area():
		return false

	# Проекция ограничивающего параллелепипеда по двум осям камеры.
	var middle := Vector3(
		float(bounds.position.x) + float(bounds.size.x) * 0.5,
		(elevation.x + elevation.y) * 0.5,
		float(bounds.position.y) + float(bounds.size.y) * 0.5)
	var half := Vector3(
		float(bounds.size.x) * 0.5,
		maxf(0.0, (elevation.y - elevation.x) * 0.5),
		float(bounds.size.y) * 0.5)
	var delta := middle - camera_position
	var radius_right := absf(right.x) * half.x + absf(right.y) * half.y \
		+ absf(right.z) * half.z
	var radius_up := absf(up.x) * half.x + absf(up.y) * half.y \
		+ absf(up.z) * half.z
	var half_width := vertical_size * maxf(aspect, 0.25) * 0.5
	var half_height := vertical_size * 0.5
	return absf(right.dot(delta)) <= half_width + radius_right + padding \
		and absf(up.dot(delta)) <= half_height + radius_up + padding

static func horizontal_intersects(bounds: Rect2i, camera_position: Vector3,
		right: Vector3, vertical_size: float, aspect: float,
		padding: float = 1.5) -> bool:
	if not bounds.has_area():
		return false
	# При повороте камеры вокруг горизонтальной оси точная высота снова нужна.
	# В штатной изометрической камере боковая ось лежит в плоскости X/Z.
	if absf(right.y) > 0.000001:
		return true
	var half_x := float(bounds.size.x) * 0.5
	var half_z := float(bounds.size.y) * 0.5
	var dx := float(bounds.position.x) + half_x - camera_position.x
	var dz := float(bounds.position.y) + half_z - camera_position.z
	var projected := right.x * dx + right.z * dz
	var radius := absf(right.x) * half_x + absf(right.z) * half_z
	var viewport_half := vertical_size * maxf(aspect, 0.25) * 0.5
	return absf(projected) <= viewport_half + radius + padding
