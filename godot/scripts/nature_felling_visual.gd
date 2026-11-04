extends RefCounted
## Краткие эффекты на видимых деревьях. Ресурс учитывает только реестр.
## При уходе чанка с экрана анимация удаляется без повторного запуска.

const Models = preload("res://scripts/nature_asset_library.gd")

const DURATION := 0.85
const HIT_DURATION := 0.32

static var _chips_mesh: Mesh


static func angle_for(id: int, seed: int) -> float:
    return deg_to_rad(float(posmod(id * 73 + seed, 360)))


static func _chips() -> Mesh:
    if _chips_mesh != null:
        return _chips_mesh

    # Все щепки образуют один маленький меш; ни одной отдельной ноды.
    var vertices := PackedVector3Array()
    var colors := PackedColorArray()
    for index in range(8):
        var angle := TAU * float(index) / 8.0
        var direction := Vector3(cos(angle), 0.0, sin(angle))
        var side := Vector3(-direction.z, 0.0, direction.x)
        var start := direction * 0.06 + Vector3(0.0, 0.37, 0.0)
        vertices.append(start)
        vertices.append(start + direction * 0.27 + side * 0.07 +
            Vector3(0.0, 0.16, 0.0))
        vertices.append(start + direction * 0.23 - side * 0.06 +
            Vector3(0.0, 0.04, 0.0))
        for vertex in range(3):
            colors.append(Color(0.67, 0.42, 0.20) if index % 2 == 0
                else Color(0.49, 0.29, 0.13))

    var arrays := []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_COLOR] = colors
    var mesh := ArrayMesh.new()
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

    var material := StandardMaterial3D.new()
    material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    material.cull_mode = BaseMaterial3D.CULL_DISABLED
    material.vertex_color_use_as_albedo = true
    mesh.surface_set_material(0, material)
    _chips_mesh = mesh
    return mesh


static func make_hit_visual(world: RefCounted,
        previous: Dictionary) -> Node3D:
    if previous.get("kind") != "дерево" or previous.get("state") not in [
            "целое", "сухостой"]:
        return null
    var position := Vector2(float(previous["x"]) + 0.5,
        float(previous["y"]) + 0.5)
    var elevation: float = world.height_at(position)
    if not is_finite(elevation):
        return null

    var root := Node3D.new()
    root.name = "Щепки дерева"
    root.position = world.config.to_scene(position, elevation)
    root.rotation.y = angle_for(int(previous["id"]), world.config.seed)
    var chips := MeshInstance3D.new()
    chips.mesh = _chips()
    chips.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    root.add_child(chips)
    return root


static func animate_hit(root: Node3D) -> void:
    if root == null or not root.is_inside_tree():
        return
    var destination := root.position + Vector3(0.0, 0.24, 0.0)
    var tween := root.create_tween()
    tween.set_parallel(true)
    tween.tween_property(root, "scale", Vector3.ONE * 1.45,
        HIT_DURATION).set_trans(Tween.TRANS_QUAD)
    tween.tween_property(root, "position", destination, HIT_DURATION)
    tween.chain().tween_callback(root.queue_free)


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
    # Короткая отдача последнего удара, затем инерционное падение.
    tween.tween_property(pivot, "rotation:z", 0.06,
        0.09).set_trans(Tween.TRANS_SINE)
    tween.tween_property(pivot, "rotation:z", -0.04, 0.08)
    tween.tween_property(pivot, "rotation:z", -PI * 0.5,
        DURATION).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
    tween.tween_interval(0.15)
    tween.tween_callback(pivot.queue_free)
