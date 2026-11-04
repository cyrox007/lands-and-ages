extends RefCounted
## Воспроизводимый маршрут камеры: доли карты и кадры фиксированы.
## Параметры не зависят от производительности устройства.

const VERSION := 1
const INITIAL_ZOOM := 66.0
const SEGMENTS := [
	["холодный_старт", 0.50, 0.50, 66.0, 20],
	["приближение", 0.50, 0.50, 28.0, 24],
	["короткий_проход", 0.62, 0.50, 28.0, 42],
	["обратный_проход", 0.50, 0.50, 28.0, 42],
	["дальний_проход", 0.82, 0.22, 28.0, 54],
	["пересечение_карты", 0.18, 0.78, 28.0, 64],
	["отдаление", 0.50, 0.50, 105.0, 32],
	["обратное_приближение", 0.50, 0.50, 28.0, 28],
	["завершение_очереди", 0.50, 0.50, 28.0, 64]
]


static func samples(width: int, height: int) -> Array[Dictionary]:
	var route: Array[Dictionary] = []
	var previous := Vector2(float(width), float(height)) * 0.5
	var previous_zoom := INITIAL_ZOOM
	for segment in SEGMENTS:
		var name: String = segment[0]
		var target := Vector2(float(segment[1]) * float(width),
			float(segment[2]) * float(height))
		var target_zoom: float = segment[3]
		var frames: int = segment[4]
		for index in range(1, frames + 1):
			var progress := float(index) / float(frames)
			route.append({
				"phase": name,
				"center": previous.lerp(target, progress),
				"zoom": lerpf(previous_zoom, target_zoom, progress)
			})
		previous = target
		previous_zoom = target_zoom
	return route
