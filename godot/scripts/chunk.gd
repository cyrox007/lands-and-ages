extends RefCounted
## Один чанк: индексированный GPU-меш и партия деревьев.
## Создание производится по запросу, никогда не выполняется каждый кадр.

const Terrain = preload("res://scripts/terrain.gd")
const Climate = preload("res://scripts/climate.gd")
const Relief = preload("res://scripts/relief.gd")
const SIZE := 16

static func cover_color(surface: Dictionary) -> Color:
	var fertility: float = surface["fertility"]
	match str(surface["cover"]):
		"grass":
			return Color(0.25 + fertility * 0.10, 0.35 + fertility * 0.12, 0.21)
		"bare":
			return Color(0.40, 0.31, 0.23)
		"sand":
			return Color(0.68, 0.62, 0.43)
		"rock":
			return Color(0.43, 0.44, 0.44)
		"snow":
			return Color(0.85, 0.88, 0.89)
		"ice":
			return Color(0.51, 0.75, 0.82)
		"water":
			return Color(0.16, 0.37, 0.51)
	return Color(0.39, 0.34, 0.28)


static func create_mesh(cx: int, cy: int, day: int, world: RefCounted = null) -> ArrayMesh:
	if world == null:
		world = load("res://scripts/world_map.gd").new()
	var bounds: Rect2i = world.config.chunk_rect(Vector2i(cx, cy))
	assert(bounds.has_area(), "Чанк вне границ мира")
	var x0 := bounds.position.x
	var y0 := bounds.position.y
	var width := bounds.size.x
	var height := bounds.size.y
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	for j in range(height + 1):
		for i in range(width + 1):
			var x := x0 + i
			var y := y0 + j
			var vertex := Vector2i(x, y)
			var h: float = world.vertex_at(vertex)
			var normal: Vector3 = world.normal_at(vertex)
			vertices.push_back(world.config.to_scene(Vector2(float(x), float(y)), h))
			normals.push_back(normal)
			colors.push_back(Relief.relief_color(h, normal))
	var stride := width + 1
	for j in range(height):
		for i in range(width):
			var a := j * stride + i
			var b := a + 1
			var c := a + stride
			var d := c + 1
			# Та же диагональ, что используется в высотной модели.
			indices.append_array(PackedInt32Array([a, c, b, d, b, c]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func create_trees(cx: int, cy: int, day: int,
		trunk_mesh: Mesh, crown_mesh: Mesh, seed: int = Terrain.SEED) -> Node3D:
	var root := Node3D.new()
	root.name = "Растительность"
	var positions: Array[Vector3] = []
	for y in range(cy * SIZE + 1, mini((cy + 1) * SIZE, Terrain.HEIGHT), 3):
		for x in range(cx * SIZE + 1, mini((cx + 1) * SIZE, Terrain.WIDTH), 3):
			if Terrain.hash2(x, y, seed + 1801) < 0.48:
				continue
			var surface := Climate.surface_at(x, y, day, seed)
			if surface["substrate"] != "soil" or float(surface["grass"]) < 0.3:
				continue
			var h := Terrain.ground_height(float(x) + 0.5, float(y) + 0.5, seed)
			positions.append(Vector3(float(x) + 0.5, h * Terrain.HEIGHT_SCALE, float(y) + 0.5))
	if positions.is_empty():
		return root
	var trunks := MultiMesh.new()
	trunks.transform_format = MultiMesh.TRANSFORM_3D
	trunks.mesh = trunk_mesh
	trunks.instance_count = positions.size()
	var crowns := MultiMesh.new()
	crowns.transform_format = MultiMesh.TRANSFORM_3D
	crowns.mesh = crown_mesh
	crowns.instance_count = positions.size()
	for i in range(positions.size()):
		var p := positions[i]
		var scale_value := 0.78 + Terrain.hash2(i, cx + cy * 23, seed + 1802) * 0.42
		var basis := Basis.IDENTITY.scaled(Vector3.ONE * scale_value)
		trunks.set_instance_transform(i, Transform3D(basis, p + Vector3.UP * (0.8 * scale_value)))
		crowns.set_instance_transform(i, Transform3D(basis, p + Vector3.UP * (2.15 * scale_value)))
	var trunks_node := MultiMeshInstance3D.new()
	trunks_node.name = "Стволы"
	trunks_node.multimesh = trunks
	trunks_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(trunks_node)
	var crowns_node := MultiMeshInstance3D.new()
	crowns_node.name = "Кроны"
	crowns_node.multimesh = crowns
	crowns_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(crowns_node)
	return root
