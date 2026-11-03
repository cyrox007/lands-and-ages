extends RefCounted
## Отрисовка только водной поверхности; все её уровни берутся из гидрологии.

static func _quad(tool: SurfaceTool, a: Vector3, b: Vector3,
		c: Vector3, d: Vector3, tint: Color) -> void:
	tool.set_color(tint)
	tool.set_normal(Vector3.UP)
	for vertex in [a, b, c, a, c, d]:
		tool.add_vertex(vertex)


static func create_mesh(world: RefCounted, hydro: RefCounted, chunk: Vector2i,
		surface: RefCounted = null) -> ArrayMesh:
	hydro.ensure_ready()
	var bounds: Rect2i = world.config.chunk_rect(chunk)
	var result := ArrayMesh.new()
	if not bounds.has_area():
		return result
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var added := 0
	for y in range(bounds.position.y, bounds.end.y):
		for x in range(bounds.position.x, bounds.end.x):
			var cell := Vector2i(x, y)
			var index: int = hydro.cell_index(cell)
			if not hydro.has_water(index):
				continue
			var level: float = hydro.level_at(index) + 0.018
			var lake: bool = hydro.lake_at(index)
			var ocean: bool = hydro.ocean_at(index)
			var river: bool = hydro.river_at(index)
			var color := Color(0.17, 0.39, 0.58, 0.87)
			if ocean:
				color = Color(0.12, 0.29, 0.47, 0.88)
			elif lake:
				color = Color(0.14, 0.33, 0.49, 0.90)
			elif not river:
				color = Color(0.23, 0.54, 0.65, 0.82)
			if surface != null:
				var state: Dictionary = surface.profile_at(cell)
				# Лёд проявляется постепенно по мере промерзания воды.
				var ice: float = smoothstep(0.20, 0.90, float(state["frost"]))
				color = color.lerp(Color(0.72, 0.85, 0.93, 0.96), ice)
			if ocean or lake or not river:
				var a: Vector3 = world.config.to_scene(Vector2(x, y), level)
				var b: Vector3 = world.config.to_scene(Vector2(x + 1, y), level)
				var c: Vector3 = world.config.to_scene(Vector2(x + 1, y + 1), level)
				var d: Vector3 = world.config.to_scene(Vector2(x, y + 1), level)
				_quad(tool, a, b, c, d, color)
				added += 1
				continue

			# Течение — лента от середины клетки к её следующему узлу.
			var next: int = hydro.downstream_of(index)
			var start := Vector2(float(x) + 0.5, float(y) + 0.5)
			var finish := start
			var end_level := level
			if next >= 0:
				var target: Vector2i = hydro.cell_from_index(next)
				finish = Vector2(float(target.x) + 0.5, float(target.y) + 0.5)
				if hydro.has_water(next):
					end_level = hydro.level_at(next) + 0.018
				else:
					end_level = world.height_at(finish) + 0.06
			else:
				finish += Vector2(0.0, 0.18)
			var direction := (finish - start).normalized()
			var normal := Vector2(-direction.y, direction.x) * 0.24
			var a: Vector3 = world.config.to_scene(start - normal, level)
			var b: Vector3 = world.config.to_scene(start + normal, level)
			var c: Vector3 = world.config.to_scene(finish + normal, end_level)
			var d: Vector3 = world.config.to_scene(finish - normal, end_level)
			_quad(tool, a, b, c, d, color)
			added += 1
	if added > 0:
		tool.commit(result)
	return result
