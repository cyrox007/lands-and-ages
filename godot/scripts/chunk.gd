extends RefCounted
## GPU-меш только показывает состояние WorldMap, Surface и Climate.

const Relief = preload("res://scripts/relief.gd")
const Appearance = preload("res://scripts/landscape_appearance.gd")
const MaterialMix = preload("res://scripts/terrain_material_mix.gd")
const ShoreVisual = preload("res://scripts/shore_visual.gd")

static func create_mesh(cx: int, cy: int, day: int, world: RefCounted = null,
		surface: RefCounted = null, mode: int = 0,
		climate: RefCounted = null, hydro: RefCounted = null) -> ArrayMesh:
	if world == null:
		world = load("res://scripts/world_map.gd").new()
	if mode == 0 and surface != null and hydro != null:
		hydro.ensure_ready()
		surface.ensure_ready()
	return mesh_from_arrays(prepare_arrays(
		cx, cy, day, world, surface, mode, climate, hydro))


static func prepare_arrays(cx: int, cy: int, _day: int,
		world: RefCounted, surface: RefCounted = null,
		mode: int = 0, climate: RefCounted = null,
		hydro: RefCounted = null) -> Array:
	# Этот метод только читает физическую модель и собирает локальные
	# PackedArray. В воркере запрещены изменение модели и вызовы сцены.

	var bounds: Rect2i = world.config.chunk_rect(Vector2i(cx, cy))
	assert(bounds.has_area(), "Чанк вне границ мира")
	var x0 := bounds.position.x
	var y0 := bounds.position.y
	var width := bounds.size.x
	var height := bounds.size.y
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var conditions := PackedByteArray()
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
			if mode == 0 and surface != null and hydro != null:
				var color := Appearance.color_at(vertex, h, normal,
					world, surface, hydro)
				var sample: Dictionary = MaterialMix.sample_at(
					vertex, h, normal, world, surface, hydro)
				var weights: PackedFloat32Array = sample["weights"]
				var natural: Vector4 = sample["conditions"]
				# Уплотнённые RGBA8: влага, морской берег, мороз, пресный берег.
				# Дополнительно 4 байта на вершину, без отдельного меша.
				for amount in [natural.x, natural.y, natural.z, natural.w]:
					conditions.append(roundi(clampf(amount, 0.0, 1.0) * 255.0))
				# Текстурные веса передаются в UV/UV2 и альфа-канале,
				# а цвет RGB остаётся доступен прежним диагностическим тестам.
				color.a = weights[MaterialMix.SNOW]
				colors.push_back(color)
				uvs.push_back(Vector2(weights[MaterialMix.SAND],
					weights[MaterialMix.ROCK]))
				uv2s.push_back(Vector2(weights[MaterialMix.SOIL],
					weights[MaterialMix.GRAVEL]))
			else:
				uvs.push_back(Vector2.ZERO)
				uv2s.push_back(Vector2.ZERO)
				conditions.append_array(PackedByteArray([0, 0, 0, 0]))
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
			# Только пересечение физического уровня с морем/озером
			# получает согласованную с водой визуальную сетку.
			# На границах клетки билинейная высота точно повторяет
			# исходные рёбра: нет зазора с обычным чанк-мешем.
			if mode == 0 and ShoreVisual.is_coastal_cell(world, hydro,
					Vector2i(x0 + i, y0 + j)):
				var subdivisions: int = ShoreVisual.SUBDIVISIONS
				var fine := PackedInt32Array()
				for sy in range(subdivisions + 1):
					var v := float(sy) / float(subdivisions)
					for sx in range(subdivisions + 1):
						var u := float(sx) / float(subdivisions)
						fine.append(vertices.size())
						var top := vertices[a].lerp(vertices[b], u)
						var bottom := vertices[c].lerp(vertices[d], u)
						vertices.append(top.lerp(bottom, v))
						var na := normals[a].lerp(normals[b], u)
						var nb := normals[c].lerp(normals[d], u)
						normals.append(na.lerp(nb, v).normalized())
						var ca := colors[a].lerp(colors[b], u)
						var cb := colors[c].lerp(colors[d], u)
						colors.append(ca.lerp(cb, v))
						uvs.append(uvs[a].lerp(uvs[b], u).lerp(
							uvs[c].lerp(uvs[d], u), v))
						uv2s.append(uv2s[a].lerp(uv2s[b], u).lerp(
							uv2s[c].lerp(uv2s[d], u), v))
						for channel in range(4):
							var t := lerpf(float(conditions[a * 4 + channel]),
								float(conditions[b * 4 + channel]), u)
							var btm := lerpf(float(conditions[c * 4 + channel]),
								float(conditions[d * 4 + channel]), u)
							conditions.append(clampi(roundi(lerpf(t, btm, v)), 0, 255))
				for sy in range(subdivisions):
					for sx in range(subdivisions):
						var top_left := sy * (subdivisions + 1) + sx
						var fa := fine[top_left]
						var fb := fine[top_left + 1]
						var fc := fine[top_left + subdivisions + 1]
						var fd := fine[top_left + subdivisions + 2]
						indices.append_array(PackedInt32Array([fa, fc, fb, fd, fb, fc]))
			else:
				# Вдали от береговой зоны геометрия и цена остаются прежними.
				indices.append_array(PackedInt32Array([a, c, b, d, b, c]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_CUSTOM0] = conditions
	arrays[Mesh.ARRAY_INDEX] = indices
	return arrays


static func mesh_from_arrays(arrays: Array) -> ArrayMesh:
	# Только главный поток создаёт ресурсы GPU.
	var mesh := ArrayMesh.new()
	var flags := Mesh.ARRAY_CUSTOM_RGBA8_UNORM << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, flags)
	return mesh
