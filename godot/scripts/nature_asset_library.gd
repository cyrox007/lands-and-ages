extends RefCounted
## Реальные CC0-модели природы с общими мешами для MultiMesh.
## Составные GLB объединяются без потери текстур ствола и листвы.

const LEGACY_ROOT := "res://assets/nature/cc0_gobkit/"
const STYLIZED_ROOT := "res://assets/nature/quaternius_stylized/"
const WIND := preload("res://shaders/nature_gltf_wind.gdshader")

const STYLIZED := {
    "PineDetailed": "Pine_1.glb",
    "PineLight": "Pine_2.glb",
    "BirchDetailed": "Birch_1.glb",
    "BirchMedium": "Birch_2.glb",
    "BirchLight": "Birch_Lod.glb",
    "OakDetailed": "Tree_1.glb",
    "OakLight": "Tree_2.glb",
    "DeadTree": "DeadTree_1.glb",
    "DeadBirch": "DeadBirch_1.glb"
}

const HEIGHT := {
    "PineDetailed": 3.4, "PineLight": 3.4,
    "BirchDetailed": 3.1, "BirchMedium": 3.1, "BirchLight": 3.1,
    "OakDetailed": 3.0, "OakLight": 3.0,
    "DeadTree": 3.0, "DeadBirch": 3.1,
    "TreeHigh001": 3.15, "TreeHigh002": 3.15,
    "TreeMed001": 3.15, "TreeMed002": 3.15,
    "TreeLow001": 3.15, "TreeLow002": 3.15,
    "Bush001": 0.75, "Bush002": 0.75,
    "Grass001": 0.40, "Grass002": 0.40,
    "Rock001": 0.50, "Rock002": 0.50
}

static var _models: Dictionary = {}
static var _materials: Dictionary = {}


static func _collect(node: Node, parent: Transform3D, parts: Array) -> void:
    var transform := parent
    if node is Node3D:
        transform = parent * (node as Node3D).transform
    if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
        parts.append({"node": node, "transform": transform})
    for child in node.get_children():
        _collect(child, transform, parts)


static func _merge_meshes(root: Node) -> ArrayMesh:
    var parts: Array = []
    _collect(root, Transform3D.IDENTITY, parts)
    var result := ArrayMesh.new()
    for part in parts:
        var visual: MeshInstance3D = part["node"]
        var mesh: Mesh = visual.mesh
        for surface in range(mesh.get_surface_count()):
            if mesh.surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES:
                continue
            var tool := SurfaceTool.new()
            tool.begin(Mesh.PRIMITIVE_TRIANGLES)
            tool.append_from(mesh, surface, part["transform"])
            tool.commit(result)
            var target := result.get_surface_count() - 1
            result.surface_set_material(target, visual.get_active_material(surface))
    return result


static func _is_foliage(source: BaseMaterial3D) -> bool:
    # Импортируемые Quaternius GLB называют материалы Leaves/Pine_Leaves.
    # Для сторонних GLB дополнительно проверяем альфа-канал.
    var name: String = source.resource_name.to_lower()
    if source.albedo_texture != null:
        name += " " + source.albedo_texture.resource_name.to_lower()
    if "leav" in name or "leaf" in name or "needle" in name:
        return true
    if "green" in name:
        return true
    return source.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED


static func foliage_stage(season: String, species: String) -> float:
    if species in ["сосна", "ель"]:
        return 0.0
    match season:
        "весна":
            return 0.12
        "осень":
            return 0.86
    return 0.0


static func _make_wind_material(source: BaseMaterial3D,
        bounds: AABB) -> ShaderMaterial:
    var material := ShaderMaterial.new()
    material.shader = WIND
    material.set_shader_parameter("source_height", bounds.size.y)
    material.set_shader_parameter("source_base", bounds.position.y)
    material.set_shader_parameter("source_tint", source.albedo_color)
    material.set_shader_parameter("source_roughness", source.roughness)
    material.set_shader_parameter("foliage_surface", _is_foliage(source))
    if source.albedo_texture != null:
        material.set_shader_parameter("source_texture", source.albedo_texture)
        material.set_shader_parameter("has_texture", true)
    return material


static func info(key: String) -> Dictionary:
    if _models.has(key):
        return _models[key]
    if not HEIGHT.has(key):
        return {}

    var filename: String = str(STYLIZED[key]) if STYLIZED.has(key) else key + ".glb"
    var folder: String = STYLIZED_ROOT if STYLIZED.has(key) else LEGACY_ROOT
    var resource := ResourceLoader.load(folder + filename) as PackedScene
    if resource == null:
        return {}

    var instance: Node = resource.instantiate()
    var mesh: ArrayMesh = _merge_meshes(instance)
    instance.free()
    if mesh.get_surface_count() == 0:
        return {}
    var bounds: AABB = mesh.get_aabb()
    if bounds.size.y < 0.001:
        return {}

    # Каждая поверхность сохраняет собственную текстуру и альфу.
    # Ветер выполняется на GPU и не меняет физический рост деревьев.
    if STYLIZED.has(key):
        for i in range(mesh.get_surface_count()):
            var source: Material = mesh.surface_get_material(i)
            if source is BaseMaterial3D:
                mesh.surface_set_material(i, _make_wind_material(
                    source as BaseMaterial3D, bounds))

    var model := {
        "mesh": mesh,
        "base_scale": float(HEIGHT[key]) / bounds.size.y,
        "base_point": Vector3(bounds.position.x + bounds.size.x * 0.5,
            bounds.position.y,
            bounds.position.z + bounds.size.z * 0.5),
        "height": bounds.size.y,
        "vertices": 0,
        "triangles": 0
    }
    for i in range(mesh.get_surface_count()):
        var arrays: Array = mesh.surface_get_arrays(i)
        var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
        var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
        model["vertices"] += vertices.size()
        model["triangles"] += int(float(
            indices.size() if not indices.is_empty() else vertices.size()) / 3.0)

    _models[key] = model
    return model


static func placement(key: String, position: Vector3,
        growth: float = 1.0, shape: Vector3 = Vector3.ONE,
        rotation: float = 0.0) -> Transform3D:
    var model: Dictionary = info(key)
    if model.is_empty():
        return Transform3D(Basis.IDENTITY, position)
    var scale: float = float(model["base_scale"]) * growth
    var basis := Basis(Vector3.UP, rotation).scaled(shape * scale)
    var pivot: Vector3 = model["base_point"]
    return Transform3D(basis, position - basis * pivot)


static func shape_for(species: String) -> Vector3:
    match species:
        "ель":
            return Vector3(0.73, 1.13, 0.73)
        "сосна":
            return Vector3(0.95, 1.06, 0.95)
        "берёза":
            return Vector3(0.86, 1.08, 0.86)
        "дуб":
            return Vector3(1.09, 0.97, 1.09)
    return Vector3.ONE


static func rotation_for(id: int) -> float:
    return deg_to_rad(float(posmod(id * 73, 360)))


static func select_tree(age_days: int, id: int, detail: float,
        species: String = "дуб", winter: bool = false,
        state: String = "целое") -> String:
    # Выбор детерминированен и не зависит от порядка загрузки чанков.
    if state != "целое" or (winter and species in ["берёза", "дуб"]):
        return "DeadBirch" if species == "берёза" else "DeadTree"
    var young := age_days < 7 * 96
    var distant := detail < 0.42
    match species:
        "сосна", "ель":
            return "PineLight" if young or distant else "PineDetailed"
        "берёза":
            if distant:
                return "BirchLight"
            if young or detail < 0.82:
                return "BirchMedium"
            return "BirchDetailed"
        "дуб":
            return "OakLight" if young or distant else "OakDetailed"
    return "OakLight" if posmod(id, 2) == 0 else "OakDetailed"


static func select_prop(kind: String, id: int) -> String:
    var variant := posmod(id, 2) + 1
    match kind:
        "кустарник":
            return "Bush%03d" % variant
        "валун":
            return "Rock%03d" % variant
        "трава":
            return "Grass%03d" % variant
    return ""


static func wind_material(key: String) -> ShaderMaterial:
    # Старые GLB природы остаются резервным вариантом.
    if STYLIZED.has(key):
        return null
    if _materials.has(key):
        return _materials[key]
    var model: Dictionary = info(key)
    if model.is_empty():
        return null
    var source: Material = model["mesh"].surface_get_material(0)
    if not (source is BaseMaterial3D):
        return null
    var bounds: AABB = (model["mesh"] as Mesh).get_aabb()
    var material := _make_wind_material(source as BaseMaterial3D, bounds)
    _materials[key] = material
    return material


static func available_models() -> Array[String]:
    var result: Array[String] = []
    for key in HEIGHT.keys():
        if not info(key).is_empty():
            result.append(key)
    result.sort()
    return result
