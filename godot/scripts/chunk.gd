extends RefCounted
## GPU-меш только показывает состояние WorldMap, Surface и Climate.

const Relief = preload("res://scripts/relief.gd")

static func create_mesh(cx: int, cy: int, day: int, world: RefCounted = null,
		surface: RefCounted = null, mode: int = 0,
		climate: RefCounted = null) -> ArrayMesh:
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
			var cell := Vector2i(mini(x, world.config.width - 1),
				mini(y, world.config.height - 1))
			if mode == 0 or surface == null:
				colors.push_back(Relief.relief_color(h, normal))
			elif mode == 5:
				colors.push_back(surface.snow_color_at(cell))
			elif mode == 6:
				colors.push_back(surface.sediment_color_at(cell))
			elif mode == 7:
				colors.push_back(surface.water_state_color_at(cell))
			elif mode <= 2 or climate == null:
				colors.push_back(surface.color_at(cell, mode - 1))
			else:
				colors.push_back(climate.color_at(cell, mode - 3))
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
