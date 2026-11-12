extends RefCounted
## Проверенные правила четырёхсвязных дорог и подхода к фундаменту.
## Только геометрия: ресурсов или второй экономики здесь нет.

const NORTH := 1
const EAST := 2
const SOUTH := 4
const WEST := 8
const SIDES := [Vector2i(0, -1), Vector2i(1, 0),
    Vector2i(0, 1), Vector2i(-1, 0)]


static func road_mask(roads: Dictionary, cell: Vector2i) -> int:
    # Читаем исключительно завершённые участки: пока дороги нет,
    # ни соседство, ни изображение не должны притворяться проходимыми.
    if not bool(roads.get(cell, false)):
        return 0
    var mask := 0
    for index in range(SIDES.size()):
        if bool(roads.get(cell + SIDES[index], false)):
            mask |= 1 << index
    return mask


static func road_kind(mask: int) -> String:
    # Связность определяет вид дорожного покрытия, а не ресурсы
    # или скорость рабочего. Поддерживаются все 16 комбинаций.
    var count := 0
    for bit in [NORTH, EAST, SOUTH, WEST]:
        if (mask & bit) != 0:
            count += 1
    if count == 0:
        return "isolated"
    if count == 1:
        return "end"
    if count == 2:
        if mask == (NORTH | SOUTH) or mask == (EAST | WEST):
            return "straight"
        return "corner"
    if count == 3:
        return "junction"
    return "crossroads"


static func perimeter(footprint: Rect2i,
        bounds: Rect2i) -> Array[Vector2i]:
    # Рабочие должны подходить к физической стене снаружи.
    # Отсекаем повторные клетки, внутренний фундамент и край карты;
    # воду, склон и препятствия проверит WorldResourcePath.walkable.
    var result: Array[Vector2i] = []
    if not footprint.has_area() or not bounds.has_area():
        return result
    var visited := {}
    for y in range(footprint.position.y,
            footprint.position.y + footprint.size.y):
        for x in range(footprint.position.x,
                footprint.position.x + footprint.size.x):
            for side in SIDES:
                var next := Vector2i(x, y) + side
                if not bounds.has_point(next) or footprint.has_point(next) \
                        or visited.has(next):
                    continue
                visited[next] = true
                result.append(next)
    return result
