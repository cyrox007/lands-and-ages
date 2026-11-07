extends RefCounted
## Географический край мира: он не является маской запрета плавания.
## Генератор v3 изменяет только обрамление ландшафта; настоящий предел — размер карты.

const COAST := "побережье"
const RIDGE := "горный хребет"
const HIGHLANDS := "скалистое нагорье"
const INTERIOR := "внутренняя территория"
const SEA_LEVEL := 0.0


static func _style(side: int, world_seed: int) -> String:
	match posmod(side + world_seed, 4):
		0, 3:
			return COAST
		1:
			return RIDGE
	return HIGHLANDS


static func _band(width: int, height: int) -> float:
	return clampf(float(mini(width, height)) * 0.17, 10.0, 42.0)


static func _side_info(x: float, y: float, width: int, height: int,
		world_seed: int, side: int) -> Dictionary:
	var distance := x
	var along := y
	if side == 1:
		distance = float(width) - x
	elif side == 2:
		distance = y
		along = x
	elif side == 3:
		distance = float(height) - y
		along = x
	var width_value := _band(width, height)
	var wave := 5.0 * sin(along / 29.0 + float(world_seed % 991) * 0.037 + float(side) * 1.7)
	wave += 2.5 * sin(along / 11.0 + float(world_seed % 947) * 0.052 + float(side) * 2.3)
	var influence := 1.0 - smoothstep(0.0, width_value, maxf(0.0, distance + wave))
	var style := _style(side, world_seed)
	var target := 8.0 + 2.5 * sin(along / 22.0 + float(world_seed % 311) * 0.11)
	if style == COAST:
		target = -5.8 + 1.1 * sin(along / 27.0 + float(world_seed % 251) * 0.09)
	elif style == RIDGE:
		# Пограничные хребты не должны выглядеть холмиками:
		# высота опирается на ту же физическую границу мира.
		target = 20.0 + 7.0 * sin(along / 19.0 + float(world_seed % 293) * 0.1)
	return {"style": style, "influence": influence, "target": target}


static func geography_at(x: float, y: float, width: int, height: int, world_seed: int) -> Dictionary:
	var strongest := 0.0
	var sum_weights := 0.0
	var sum_height := 0.0
	var dominant := INTERIOR
	for side in range(4):
		var info := _side_info(x, y, width, height, world_seed, side)
		var influence: float = info["influence"]
		if influence > strongest:
			strongest = influence
			dominant = str(info["style"])
		sum_weights += influence
		sum_height += influence * float(info["target"])
	return {
		"zone": dominant if strongest > 0.12 else INTERIOR,
		"influence": clampf(sum_weights, 0.0, 1.0),
		"target": sum_height / sum_weights if sum_weights > 0.0 else 0.0
	}


static func height_at(x: float, y: float, width: int, height: int,
		world_seed: int, base: float) -> float:
	var edge := geography_at(x, y, width, height, world_seed)
	return lerpf(base, float(edge["target"]), float(edge["influence"]))


static func traversal_gate(config: RefCounted, destination: Vector2,
		water_present: bool, has_water_travel: bool) -> String:
	# Запрет существует только у внешнего предела карты.
	# Река, озеро и море внутри могут пересекаться при подходящей механике.
	if not config.contains_point(destination):
		return "за пределами мира"
	if water_present and not has_water_travel:
		return "требуется способ пересечения воды"
	return "внутри мира"
