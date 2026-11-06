extends RefCounted
## Этап 11.2/L2: реальные тени только рядом с камерой.
## Здесь нет обращений к физике — на удалённых чанках меняются
## исключительно свойства рендера, а не высоты и коллизии.

const MAX_SHADOW_ZOOM := 62.0
const FADE_START_ZOOM := 50.0
const TERRAIN_RADIUS := 2
const NATURE_RADIUS := 1


static func active(zoom: float, mode: int) -> bool:
	## Полные тени включены только в природном режиме при ближнем
	## масштабе. Диагностические виды и обзорная карта дешевле.
	return is_finite(zoom) and zoom < MAX_SHADOW_ZOOM and mode == 0


static func shadow_opacity_for_zoom(zoom: float, mode: int) -> float:
	## Плавно скрываем геометрические тени до отсечки карты.
	## Переход считается из абсолютного размера камеры: результат не
	## зависит от порядка приближения и от количества кадров.
	if not active(zoom, mode):
		return 0.0
	# На ближнем масштабе сохраняем всю силу настоящей тени.
	# На дальнем её уже замещает непрерывный рельефный L3.
	return 1.0 - smoothstep(FADE_START_ZOOM, MAX_SHADOW_ZOOM, zoom)


static func chunk_casts(coord: Vector2i, center_chunk: Vector2i,
		zoom: float, mode: int, is_nature: bool = false) -> bool:
	## Ограничиваем число затеняющих чанков квадратом 5×5 для грунта
	## и 3×3 для природных объектов. Число не зависит от размера мира.
	if not active(zoom, mode):
		return false
	var distance := maxi(absi(coord.x - center_chunk.x),
		absi(coord.y - center_chunk.y))
	var radius := NATURE_RADIUS if is_nature else TERRAIN_RADIUS
	return distance <= radius


static func configure_chunk(chunk: Node3D, ground_casts: bool,
		nature_casts: bool) -> void:
	## Меняем только свойства MeshInstance3D и MultiMeshInstance3D.
	## Вода намеренно не отбрасывает тени как твёрдая геометрия.
	var ground := chunk.get_node_or_null("Рельеф") as MeshInstance3D
	if ground != null:
		ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON 			if ground_casts else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var forest := chunk.get_node_or_null("Природные объекты")
	if forest == null:
		return
	for child in forest.get_children():
		# У рендера природы по одному MultiMesh на группу пород.
		# Не создаём объекты света или тени для отдельных деревьев.
		if child is GeometryInstance3D and child.name != "дым":
			child.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON 				if nature_casts else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
