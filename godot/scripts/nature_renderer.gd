extends RefCounted
## GPU-инстансы природных объектов. Временные модели заменятся CC0 glTF.
## Вне видимых чанков узлы/анимация не создаются.

const Wind = preload("res://shaders/nature_wind.gdshader")

static var _meshes: Dictionary = {}
static var _materials: Dictionary = {}


static func _mesh(kind: String) -> Mesh:
    if _meshes.has(kind):
        return _meshes[kind]
    var mesh: PrimitiveMesh
    if kind in ["ствол", "пень"]:
        var cylinder := CylinderMesh.new()
        cylinder.top_radius = 0.10 if kind == "ствол" else 0.16
        cylinder.bottom_radius = 0.17 if kind == "ствол" else 0.19
        cylinder.height = 2.0 if kind == "ствол" else 0.22
        cylinder.radial_segments = 8
        mesh = cylinder
    elif kind == "хвоя":
        var cone := CylinderMesh.new()
        cone.top_radius = 0.0
        cone.bottom_radius = 0.83
        cone.height = 2.3
        cone.radial_segments = 9
        mesh = cone
    else:
        var sphere := SphereMesh.new()
        sphere.radius = 0.90 if kind == "листва" else (
            0.43 if kind == "куст" else 0.40)
        sphere.height = 1.8 if kind == "листва" else (
            0.86 if kind == "куст" else 0.60)
        sphere.radial_segments = 10
        sphere.rings = 5
        mesh = sphere
    if kind in ["хвоя", "листва", "куст"]:
        var wind := ShaderMaterial.new()
        wind.shader = Wind
        mesh.material = wind
    else:
        var material := StandardMaterial3D.new()
        material.vertex_color_use_as_albedo = true
        material.roughness = 0.98
        mesh.material = material
    _meshes[kind] = mesh
    return mesh


static func _color(kind: String, species: String, state: String) -> Color:
    if kind in ["ствол", "пень"]:
        return Color(0.30, 0.22, 0.14) if state != "сухостой" else Color(0.44, 0.40, 0.32)
    if kind == "камень":
        return Color(0.46, 0.48, 0.43)
    if kind == "куст":
        return Color(0.17, 0.34, 0.12)
    match species:
        "сосна":
            return Color(0.16, 0.31, 0.16)
        "ель":
            return Color(0.10, 0.25, 0.15)
        "берёза":
            return Color(0.29, 0.42, 0.18)
        "дуб":
            return Color(0.25, 0.36, 0.14)
    return Color(0.20, 0.34, 0.16)


static func _push(groups: Dictionary, kind: String, transform: Transform3D,
        color: Color, phase: float) -> void:
    if not groups.has(kind):
        groups[kind] = []
    groups[kind].append({
        "transform": transform, "color": color,
        "phase": phase
    })


static func create_chunk(world: RefCounted, nature: RefCounted,
        coord: Vector2i) -> Node3D:
    var result := Node3D.new()
    result.name = "Природные объекты"
    if nature == null or not nature.generated:
        return result
    var groups := {}
    for item in nature.objects_in_chunk(coord):
        var position := Vector2(float(item["x"]) + 0.5,
            float(item["y"]) + 0.5)
        var ground: float = world.height_at(position)
        if not is_finite(ground):
            continue
        var origin: Vector3 = world.config.to_scene(position, ground)
        var species: String = item["species"]
        var state: String = item["state"]
        var age: int = item["age_days"]
        var scale_factor := clampf(float(age) / (20.0 * 96.0), 0.20, 1.25)
        var phase := float(posmod(int(item["id"]), 251)) / 251.0
        if item["kind"] == "дерево":
            if state == "пень":
                _push(groups, "пень",
                    Transform3D(Basis.IDENTITY, origin + Vector3(0, 0.11, 0)),
                    _color("пень", species, state), phase)
                continue
            var trunk_base := Basis.IDENTITY.scaled(
                Vector3(scale_factor, scale_factor, scale_factor))
            _push(groups, "ствол",
                Transform3D(trunk_base, origin +
                    Vector3(0, scale_factor, 0)),
                _color("ствол", species, state), phase)
            if state == "целое":
                var foliage: String = "хвоя" if species in ["сосна", "ель"] else "листва"
                _push(groups, foliage,
                    Transform3D(trunk_base, origin +
                        Vector3(0, 2.15 * scale_factor, 0)),
                    _color(foliage, species, state), phase)
        elif item["kind"] == "кустарник":
            _push(groups, "куст",
                Transform3D(Basis.IDENTITY,
                    origin + Vector3(0, 0.36, 0)),
                _color("куст", species, state), phase)
        elif item["kind"] == "валун":
            _push(groups, "камень",
                Transform3D(Basis.IDENTITY, origin + Vector3(0, 0.26, 0)),
                _color("камень", species, state), phase)

    for kind in groups.keys():
        var instances: Array = groups[kind]
        var multi := MultiMesh.new()
        multi.transform_format = MultiMesh.TRANSFORM_3D
        multi.use_colors = true
        multi.use_custom_data = true
        multi.mesh = _mesh(kind)
        multi.instance_count = instances.size()
        for i in range(instances.size()):
            var entry: Dictionary = instances[i]
            multi.set_instance_transform(i, entry["transform"])
            multi.set_instance_color(i, entry["color"])
            multi.set_instance_custom_data(i,
                Color(float(entry["phase"]), 0, 0, 0))
        var node := MultiMeshInstance3D.new()
        node.name = str(kind)
        node.multimesh = multi
        node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
        result.add_child(node)
    return result
