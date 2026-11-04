extends RefCounted
## Общая геометрия лежащего бревна для логики и физики.
## Не зависит от сцены, камеры, GPU и кадровой частоты.


static func angle_for(id: int, object_seed: int) -> float:
    return deg_to_rad(float(posmod(id * 73 + object_seed, 360)))


static func log_footprint(item: Dictionary,
        config: RefCounted) -> Dictionary:
    if item.get("kind") != "дерево" or item.get("state") != "пень" \
            or int(item.get("fallen_wood", 0)) <= 0:
        return {}
    var tree := Vector2(float(item["x"]) + 0.5,
        float(item["y"]) + 0.5)
    var angle := angle_for(int(item["id"]), config.seed)
    var center: Vector2 = config.clamp_point(tree +
        Vector2(cos(angle), sin(angle)) * 0.70)
    var scale := clampf(float(item["age_days"]) / (20.0 * 96.0),
        0.25, 1.0)
    return {
        "center": center, "angle": angle,
        "axis": Vector2(cos(angle), -sin(angle)),
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
