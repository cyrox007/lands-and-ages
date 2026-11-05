extends RefCounted
## Общая геометрия лежащего бревна для логики и физики.
## Не зависит от сцены, камеры, GPU и кадровой частоты.


static func angle_for(id: int, world_seed: int) -> float:
    return deg_to_rad(float(posmod(id * 73 + world_seed, 360)))


static func log_footprint(item: Dictionary,
        config: RefCounted) -> Dictionary:
    if item.get("kind") != "дерево" or item.get("state") != "пень" \
            or int(item.get("fallen_wood", 0)) <= 0:
        return {}
    var tree := Vector2(float(item["x"]) + 0.5,
        float(item["y"]) + 0.5)
    # Старые карты и ручная рубка сохраняют исходную геометрию.
    # Только штормовой ветровал записывает направление физического ветра.
    var degrees: int = int(item.get("fall_angle_deg", -1))
    var directed := degrees >= 0
    var angle := deg_to_rad(float(degrees)) if directed else \
        angle_for(int(item["id"]), config.world_seed)
    var axis := Vector2(cos(angle), -sin(angle))
    var offset := axis if directed else Vector2(cos(angle), sin(angle))
    var center: Vector2 = config.clamp_point(tree + offset * 0.70)
    var scale := clampf(float(item["age_days"]) / (20.0 * 96.0),
        0.25, 1.0)
    return {
        "center": center, "angle": angle,
        "axis": axis,
        "half_length": scale, "radius": 0.19 * scale
    }


static func hits_log(point: Vector2, radius: float,
        item: Dictionary, config: RefCounted) -> bool:
    var shape: Dictionary = log_footprint(item, config)
    if shape.is_empty():
        return false
    var center: Vector2 = shape["center"]
    var axis: Vector2 = shape["axis"]
    var length: float = shape["half_length"]
    var along := clampf((point - center).dot(axis), -length, length)
    var closest := center + axis * along
    return point.distance_to(closest) < float(shape["radius"]) + radius
