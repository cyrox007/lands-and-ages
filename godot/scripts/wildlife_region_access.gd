extends RefCounted
## Поиск настоящего сухопутного прохода к региональному ареалу.
## Используется охотой и отловом, а не отдельной «магией доставки».

const Paths = preload("res://scripts/world_resource_path.gd")
const DIRECTIONS := [
    Vector2i(1, 0), Vector2i(-1, 0),
    Vector2i(0, 1), Vector2i(0, -1)
]


static func entry(world: RefCounted, hydro: RefCounted,
        surface: RefCounted, origin: Vector2i,
        region: Vector2i) -> Dictionary:
    # Поиск в ширину идёт по физической проходимости карты и
    # останавливается на первой достижимой клетке нужного региона.
    # Длина пути задаёт время пешей поставки животного или туши.
    var bounds: Rect2i = world.config.region_rect(region)
    if not bounds.has_area() \
            or not Paths.walkable(world, hydro, surface, origin):
        return {}
    if bounds.has_point(origin):
        return {"cell": origin, "steps": 0}
    var width: int = world.config.width
    var count: int = width * world.config.height
    var seen := PackedByteArray()
    seen.resize(count)
    var start: int = origin.y * width + origin.x
    var queue: Array[int] = [start]
    seen[start] = 1
    var distances := PackedInt32Array()
    distances.resize(count)
    var head := 0
    while head < queue.size():
        var current: int = queue[head]
        head += 1
        var point := Vector2i(current % width, current / width)
        for direction in DIRECTIONS:
            var neighbor: Vector2i = point + direction
            if not Paths.walkable(world, hydro, surface, neighbor):
                continue
            var index: int = neighbor.y * width + neighbor.x
            if seen[index] != 0:
                continue
            seen[index] = 1
            distances[index] = distances[current] + 1
            if bounds.has_point(neighbor):
                return {"cell": neighbor, "steps": distances[index]}
            queue.append(index)
    return {}
