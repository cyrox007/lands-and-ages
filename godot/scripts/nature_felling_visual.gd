extends RefCounted
## Временная анимация рубки: состояние древесины уже изменено в физике.
## Создаётся только для активного чанка, после падения удаляется.

const Models = preload("res://scripts/nature_asset_library.gd")

const DURATION := 0.85
const HIT_DURATION := 0.32
const CHIP_COUNT := 4

static var _chip_mesh: Mesh


static func _chips() -> Mesh:
    if _chip_mesh != null:
        return _chip_mesh
    var wood := StandardMaterial3D.new()
    wood.albedo_color = Color(0.56, 0.38, 0.19)
    wood.roughness = 1.0
    var chip := BoxMesh.new()
    chip.size = Vector3(0.045, 0.11, 0.035)
    chip.material = wood
    _chip_mesh = chip
    return chip


static func make_hit_effect(world: RefCounted, before: Dictionary,
        progress: int) -> Node3D:
    # Щепки существуют только как временный визуал; древесина не меняется.
    if before.get("kind") != "дерево" or progress <= 0:
        return null
    var point := Vector2(float(before["x"]) + 0.5,
        float(before["y"]) + 0.5)
    var height: float = world.height_at(point)
    if not is_finite(height):
        return null
    var result := Node3D.new()
    result.name = "Щепки"
    result.position = world.config.to_scene(point, height)
    var phase: float = angle_for(int(before["id"]), world.config.seed)
    var level := clampf(float(before["age_days"]) / (20.0 * 96.0),
        0.20, 1.25)
    for i in range(CHIP_COUNT):
        var chip := MeshInstance3D.new()
        chip.mesh = _chips()
        var angle := phase + TAU * float(i) / float(CHIP_COUNT)
        chip.position = Vector3(cos(angle) * 0.08, level * 0.45,
            sin(angle) * 0.08)
        chip.rotation.y = angle
        chip.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
        result.add_child(chip)
    return result


static func animate_hit(effect: Node3D) -> void:
    if effect == null or not effect.is_inside_tree():
        return
    var tween := effect.create_tween().set_parallel(true)
    for i in range(effect.get_child_count()):
        var chip: Node3D = effect.get_child(i)
        var angle := TAU * float(i) / float(CHIP_COUNT)
        var flight := Vector3(cos(angle) * 0.35, 0.24,
            sin(angle) * 0.35)
        tween.tween_property(chip, "position",
            chip.position + flight, HIT_DURATION)
        tween.tween_property(chip, "scale", Vector3.ZERO,
            HIT_DURATION)
    tween.chain().tween_callback(effect.queue_free)



static func angle_for(id: int, seed: int) -> float:
    return deg_to_rad(float(posmod(id * 73 + seed, 360)))


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
