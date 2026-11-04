extends RefCounted
## Общая ТОЛЬКО визуальная геометрия берега для суши и воды.
## WorldMap.height_at, физические вершины и гидрология не меняются.

const SUBDIVISIONS := 3


static func height(ha: float, hb: float, hc: float, hd: float,
		u: float, v: float) -> float:
	# Билинейная визуальная высота. На каждой стороне ячейки она
	# точно линейна, поэтому совпадает и с соседней грубой ячейкой.
	return lerpf(lerpf(ha, hb, u), lerpf(hc, hd, u), v)


static func is_coastal_cell(world: RefCounted, hydro: RefCounted,
		cell: Vector2i) -> bool:
	if hydro == null:
		return false
	var index: int = hydro.cell_index(cell)
	if not hydro.has_water(index):
		return false
	# Речная лента без озера/моря пока строится отдельно.
	if hydro.river_at(index) and not hydro.lake_at(index) \
			and not hydro.ocean_at(index):
		return false
	var level: float = hydro.level_at(index)
	var ha: float = world.vertex_at(cell)
	var hb: float = world.vertex_at(cell + Vector2i(1, 0))
	var hc: float = world.vertex_at(cell + Vector2i(0, 1))
	var hd: float = world.vertex_at(cell + Vector2i(1, 1))
	return minf(minf(ha, hb), minf(hc, hd)) < level \
		and maxf(maxf(ha, hb), maxf(hc, hd)) > level
