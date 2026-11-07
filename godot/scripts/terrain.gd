extends RefCounted
## Единый генератор природного рельефа: формы местности и географический край.
## Нет старых переключаемых генераторов: мир находится в активной разработке.

const Config = preload("res://scripts/world_config.gd")
const Boundary = preload("res://scripts/world_boundary.gd")
const WIDTH := Config.DEFAULT_WIDTH
const HEIGHT := Config.DEFAULT_HEIGHT
const SEED := Config.DEFAULT_SEED
const HEIGHT_SCALE := Config.DEFAULT_HEIGHT_SCALE
const FEATURE_STEP := 72.0
# Актуальная геометрия: одна модель, без старых вариантов высот.
const MOUNTAIN_SUMMIT := 26.0
const MOUNTAIN_RIDGE := 4.5
const FORM_NAMES := [
	"равнина", "низина", "холмы", "плоскогорье",
	"горы", "долина", "овраг"
]

static func hash2(x: int, y: int, world_seed: int) -> float:
	var n: int = (x * 374761393 + y * 668265263 + world_seed * 1442695041) & 0xffffffff
	n = ((n ^ (n >> 13)) * 1274126177) & 0xffffffff
	n = (n ^ (n >> 16)) & 0xffffffff
	return float(n) / 4294967295.0


static func _noise(x: float, y: float, world_seed: int) -> float:
	var i := floori(x)
	var j := floori(y)
	var u := smoothstep(0.0, 1.0, x - float(i))
	var v := smoothstep(0.0, 1.0, y - float(j))
	var a := lerpf(hash2(i, j, world_seed), hash2(i + 1, j, world_seed), u)
	var b := lerpf(hash2(i, j + 1, world_seed), hash2(i + 1, j + 1, world_seed), u)
	return lerpf(a, b, v) * 2.0 - 1.0


static func _form_index(gx: int, gy: int, world_seed: int) -> int:
	# Чередование предотвращает исчезновение целого вида форм на большой карте.
	# Координаты центров, развороты и подробности остаются случайными по seed.
	return posmod(gx * 3 + gy * 5 + world_seed, FORM_NAMES.size())


static func _feature(x: float, y: float, gx: int, gy: int,
		world_seed: int) -> Vector3:
	var jitter_x := (hash2(gx, gy, world_seed + 11) - 0.5) * 0.32
	var jitter_y := (hash2(gx, gy, world_seed + 12) - 0.5) * 0.32
	var cx := (float(gx) + 0.5 + jitter_x) * FEATURE_STEP
	var cy := (float(gy) + 0.5 + jitter_y) * FEATURE_STEP
	var angle := hash2(gx, gy, world_seed + 13) * TAU
	var offset := Vector2(x - cx, y - cy)
	var along := (offset.x * cos(angle) + offset.y * sin(angle)) / 34.0
	var across := (-offset.x * sin(angle) + offset.y * cos(angle)) / 30.0
	var kind := _form_index(gx, gy, world_seed)
	var r := Vector2(along, across).length()
	var envelope := 1.0 - smoothstep(0.64, 1.31, r)
	if envelope <= 0.0:
		return Vector3.ZERO
	var detail := _noise(x / 12.0, y / 12.0, world_seed + gx * 37 + gy * 41 + 141)
	var height_change := 0.0
	var flatten := 0.0
	match kind:
		0:
			# Равнина — область с подавленной мелкой неровностью.
			flatten = 0.82 * envelope
			height_change = -0.25 * envelope
		1:
			# Широкая низина без искусственно плоского дна.
			height_change = -2.9 * envelope
		2:
			height_change = 3.1 * envelope * (0.82 + 0.18 * detail)
		3:
			# Пологая широкая вершина и отчётливый край плоскогорья.
			var top := 1.0 - smoothstep(0.69, 1.16, r)
			height_change = 5.3 * top + detail * 0.1 * top
			flatten = 0.68 * top
		4:
			# Один непрерывный горный массив: широкие предгорья,
			# извилистый высокий гребень, несколько вершин и отроги.
			# Все высоты поступают в WorldMap, а не только в шейдер.
			var axis := across + 0.11 * sin(along * 3.5 + angle) \
				+ 0.035 * sin(along * 8.9 + angle * 0.7)
			var ridge := pow(1.0 - smoothstep(0.045, 0.47,
				absf(axis)), 1.45)
			var knife_edge := pow(1.0 - smoothstep(0.008, 0.17,
				absf(axis)), 2.0)
			# Вершины не равновысотны и разнесены вдоль общей
			# гряды. Седловины остаются проходимыми между ними.
			var peak_wave := 0.5 + 0.5 * sin(along * 10.5 + angle * 1.9)
			var summit := 0.69 + 0.31 * pow(peak_wave, 2.3)
			# Боковой отрог от главной оси не образует отдельной
			# изолированной кучи: пересекается с хребтом в центре.
			var spur_axis := absf(across - 0.44 * along)
			var spur := (1.0 - smoothstep(0.09, 0.37, spur_axis)) \
				* smoothstep(0.14, 0.61, absf(along))
			var foothills := 3.8 + 1.4 * detail
			height_change = envelope * (foothills
				+ (MOUNTAIN_SUMMIT * ridge + MOUNTAIN_RIDGE * knife_edge)
				* summit + 6.0 * spur)
			# Камень имеет реальные неоднородности в самом меше,
			# но без шумовых зубцов и разрывов на стыках чанков.
			height_change += envelope * ridge * detail * 0.85
		5:
			# Долина продолжается вдоль оси и мягко расширяется на выходе.
			var axis := across + 0.16 * sin(along * 3.4 + angle)
			var reach := 1.0 - smoothstep(0.78, 1.45, absf(along))
			height_change = -3.1 * exp(-1.6 * axis * axis) * reach
		6:
			# Узкое дно оврага и физические бровки питают тот же
			# водосбор; отдельной декоративной геометрии нет.
			var axis := across + 0.16 * sin(along * 4.3 + angle)
			var reach := 1.0 - smoothstep(0.81, 1.50, absf(along))
			var trench := 1.0 - smoothstep(0.10, 0.28, absf(axis))
			var shoulder := exp(-8.0 * axis * axis)
			height_change = -5.0 * (0.82 * trench + 0.18 * shoulder) * reach
	return Vector3(height_change, flatten, envelope)


static func sample(x: float, y: float, world_seed: int) -> Dictionary:
	# Крупные и мелкие шумы не зависят от размеров карты.
	var coarse := 0.85 * _noise(x / 92.0, y / 92.0, world_seed + 1001)
	var medium := 0.29 * _noise(x / 24.0, y / 24.0, world_seed + 1002)
	var fine := 0.09 * _noise(x / 6.0, y / 6.0, world_seed + 1003)
	var flatten := 0.0
	var sum_features := 0.0
	var dominant := -1
	var strongest := 0.0
	var home_x := floori(x / FEATURE_STEP)
	var home_y := floori(y / FEATURE_STEP)
	for gy in range(home_y - 1, home_y + 2):
		for gx in range(home_x - 1, home_x + 2):
			var effect := _feature(x, y, gx, gy, world_seed)
			sum_features += effect.x
			flatten = maxf(flatten, effect.y)
			if effect.z > strongest:
				strongest = effect.z
				dominant = _form_index(gx, gy, world_seed)
	var elevation := coarse + (medium + fine) * (1.0 - flatten) + sum_features
	return {
		"height": elevation,
		"form": FORM_NAMES[dominant] if dominant >= 0 and strongest >= 0.12 else "переход",
		"influence": strongest
	}


static func height_at(x: float, y: float, world_seed: int) -> float:
	return float(sample(x, y, world_seed)["height"])


static func form_at(x: float, y: float, world_seed: int) -> String:
	return str(sample(x, y, world_seed)["form"])


static func vertex_height_on_map(x: int, y: int, width: int, height: int,
		world_seed: int) -> float:
	# Географический край рассчитывается после физического профиля:
	# побережья и барьеры остаются частью общей высотной карты.
	var base := height_at(float(x), float(y), world_seed)
	return Boundary.height_at(float(x), float(y), width, height, world_seed, base)


static func vertex_height(x: int, y: int, world_seed: int = SEED) -> float:
	return vertex_height_on_map(x, y, WIDTH, HEIGHT, world_seed)


static func ground_height(x: float, y: float, world_seed: int = SEED) -> float:
	var ix := clampi(floori(x), 0, WIDTH - 1)
	var iy := clampi(floori(y), 0, HEIGHT - 1)
	var u := clampf(x - float(ix), 0.0, 1.0)
	var v := clampf(y - float(iy), 0.0, 1.0)
	var h00 := vertex_height(ix, iy, world_seed)
	var h10 := vertex_height(ix + 1, iy, world_seed)
	var h01 := vertex_height(ix, iy + 1, world_seed)
	var h11 := vertex_height(ix + 1, iy + 1, world_seed)
	if u + v <= 1.0:
		return h00 + (h10 - h00) * u + (h01 - h00) * v
	return h11 + (h01 - h11) * (1.0 - u) + (h10 - h11) * (1.0 - v)


static func normal_at(x: int, y: int, world_seed: int = SEED) -> Vector3:
	var west := vertex_height(x - 1, y, world_seed)
	var east := vertex_height(x + 1, y, world_seed)
	var north := vertex_height(x, y - 1, world_seed)
	var south := vertex_height(x, y + 1, world_seed)
	return Vector3((west - east) * HEIGHT_SCALE, 2.0, (north - south) * HEIGHT_SCALE).normalized()


static func slope_at(x: int, y: int, world_seed: int = SEED) -> float:
	var west := vertex_height(x - 1, y, world_seed)
	var east := vertex_height(x + 1, y, world_seed)
	var north := vertex_height(x, y - 1, world_seed)
	var south := vertex_height(x, y + 1, world_seed)
	return Vector2((east - west) * 0.5, (south - north) * 0.5).length()
