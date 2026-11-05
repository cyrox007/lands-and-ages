extends RefCounted
## Диагностика форм суши и воды. Не меняет рельеф и не подменяет гидрологию.
## Названия архетипов — эвристики для поиска seed, а не гарантии генератора.

const DIRECTIONS := [
    Vector2i(1, 0), Vector2i(-1, 0),
    Vector2i(0, 1), Vector2i(0, -1)
]


static func _components(water: PackedByteArray, width: int,
        height: int) -> Dictionary:
    var visited := PackedByteArray()
    visited.resize(water.size())
    var lands: Array[Dictionary] = []
    var waters: Array[Dictionary] = []
    for index in range(water.size()):
        if visited[index] != 0:
            continue
        var wet: bool = water[index] != 0
        var queue: Array[int] = [index]
        visited[index] = 1
        var cursor := 0
        var edge := false
        var min_x := width
        var min_y := height
        var max_x := 0
        var max_y := 0
        while cursor < queue.size():
            var current: int = queue[cursor]
            cursor += 1
            var x: int = current % width
            var y: int = floori(float(current) / float(width))
            min_x = mini(min_x, x)
            min_y = mini(min_y, y)
            max_x = maxi(max_x, x)
            max_y = maxi(max_y, y)
            if x == 0 or y == 0 or x == width - 1 or y == height - 1:
                edge = true
            for offset in DIRECTIONS:
                var nx: int = x + offset.x
                var ny: int = y + offset.y
                if nx < 0 or ny < 0 or nx >= width or ny >= height:
                    continue
                var next: int = ny * width + nx
                if visited[next] != 0 or (water[next] != 0) != wet:
                    continue
                visited[next] = 1
                queue.append(next)
        var component := {
            "area": queue.size(), "touches_border": edge,
            "bounds": [min_x, min_y, max_x, max_y]
        }
        if wet:
            waters.append(component)
        else:
            lands.append(component)
    lands.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
        return int(a["area"]) > int(b["area"]))
    waters.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
        return int(a["area"]) > int(b["area"]))
    return {"land": lands, "water": waters}


static func _neck_ratio(water: PackedByteArray, width: int,
        bounds: Array) -> float:
    var x0: int = bounds[0]
    var y0: int = bounds[1]
    var x1: int = bounds[2]
    var y1: int = bounds[3]
    var box_width := x1 - x0 + 1
    var box_height := y1 - y0 + 1
    if box_width < 12 or box_height < 12:
        return 1.0
    var minimum := INF
    var maximum := 0
    # У краёв фигуры узкие кончики нормальны. Измеряем внутренние сечения.
    for x in range(x0 + box_width / 5, x1 - box_width / 5 + 1):
        var section := 0
        for y in range(y0, y1 + 1):
            if water[y * width + x] == 0:
                section += 1
        if section > 0:
            minimum = minf(minimum, float(section))
            maximum = maxi(maximum, section)
    if maximum == 0:
        return 1.0
    return minimum / float(maximum)


static func classify_mask(water: PackedByteArray,
        width: int, height: int) -> Dictionary:
    var size := width * height
    if width < 1 or height < 1 or water.size() != size:
        return {"valid": false, "archetype": "неизвестно"}
    var parts: Dictionary = _components(water, width, height)
    var lands: Array = parts["land"]
    var waters: Array = parts["water"]
    var dry := 0
    var inland_water := 0
    var largest_inland := 0
    var significant_islands := 0
    var largest_land := 0
    var coastal_edges := 0
    for land in lands:
        var area: int = land["area"]
        dry += area
        largest_land = maxi(largest_land, area)
        if area >= maxi(8, ceili(float(size) * 0.012)):
            significant_islands += 1
    for region in waters:
        if not region["touches_border"]:
            var area: int = region["area"]
            inland_water += area
            largest_inland = maxi(largest_inland, area)
    for y in range(height):
        for x in range(width):
            var index := y * width + x
            if water[index] != 0:
                continue
            if x > 0 and water[index - 1] != 0:
                coastal_edges += 1
            if x + 1 < width and water[index + 1] != 0:
                coastal_edges += 1
            if y > 0 and water[index - width] != 0:
                coastal_edges += 1
            if y + 1 < height and water[index + width] != 0:
                coastal_edges += 1
    var share := float(largest_land) / float(maxi(dry, 1))
    var neck := 1.0
    if not lands.is_empty():
        neck = _neck_ratio(water, width, lands[0]["bounds"])
    var inland_sea := largest_inland >= maxi(20, ceili(float(size) * 0.018))
    var archipelago := significant_islands >= 3 and share < 0.75
    var peninsula := share > 0.65 and neck < 0.42 \
        and coastal_edges > maxi(20, width + height)
    var archetype := "смешанная"
    if dry == 0:
        archetype = "полностью затоплена"
    elif inland_sea:
        archetype = "внутреннее море"
    elif archipelago:
        archetype = "архипелаг"
    elif peninsula:
        archetype = "полуостров"
    elif share >= 0.8:
        archetype = "материк"
    return {
        "valid": true, "archetype": archetype,
        "dry_cells": dry, "water_cells": size - dry,
        "land_components": lands.size(),
        "water_components": waters.size(),
        "large_islands": significant_islands,
        "largest_land_share": snappedf(share, 0.0001),
        "largest_inland_water_cells": largest_inland,
        "inland_water_cells": inland_water,
        "coastline_edges": coastal_edges,
        "interior_neck_ratio": snappedf(neck, 0.0001),
        "archetype_is_heuristic": true
    }


static func report(world: RefCounted, hydro: RefCounted) -> Dictionary:
    hydro.ensure_ready()
    var width: int = world.config.width
    var height: int = world.config.height
    var water := PackedByteArray()
    water.resize(width * height)
    for index in range(water.size()):
        if hydro.has_water(index):
            water[index] = 1
    return classify_mask(water, width, height)
