extends RefCounted
## Временная анимация рубки: состояние древесины уже изменено в физике.
## Создаётся только для активного чанка, после падения удаляется.

const Models = preload("res://scripts/nature_asset_library.gd")
const Geometry = preload("res://scripts/nature_geometry.gd")

const DURATION := 0.85


static func angle_for(id: int, seed: int) -> float:
    return Geometry.angle_for(id, seed)


static func make_visual(world: RefCounted, previous: Dictionary,
        detail: float = 1.0) -> Node3D:
    if previous.get("kind") != "дерево" or previous.get("state") not in [
            "целое", "сухостой"]:
        return null
    var id: int = previous["id"]
    var key: String = Models.select_tree(
        int(previous["age_days"]), id, detail)
    var model: Dictionary = Models.info(key)
    if model.is_empty():
        return null

    var position := Vector2(float(previous["x"]) + 0.5,
        float(previous["y"]) + 0.5)
    var elevation: float = world.height_at(position)
    if not is_finite(elevation):
        return null

    var pivot := Node3D.new()
    pivot.name = "Падение дерева"
    pivot.position = world.config.to_scene(position, elevation)
    pivot.rotation.y = angle_for(id, world.config.seed)

    var visual := MeshInstance3D.new()
    visual.name = "Падающий ствол"
    visual.mesh = model["mesh"]
    var growth := clampf(float(previous["age_days"]) /
        (20.0 * 96.0), 0.20, 1.25)
    visual.transform = Models.placement(key, Vector3.ZERO, growth)
    visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    pivot.add_child(visual)
    return pivot


static func animate(pivot: Node3D) -> void:
    if pivot == null or not pivot.is_inside_tree():
        return
    var tween := pivot.create_tween()
    tween.tween_property(pivot, "rotation:z", -PI * 0.5,
        DURATION).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
    tween.tween_interval(0.22)
    tween.tween_callback(pivot.queue_free)
