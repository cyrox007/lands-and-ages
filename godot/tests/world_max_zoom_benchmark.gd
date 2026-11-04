extends SceneTree

const View = preload("res://scripts/world.gd")
const Metrics = preload("res://scripts/world_benchmark_metrics.gd")

func _initialize() -> void:
	_run()

func _run() -> void:
	await process_frame
	var view := View.new()
	root.add_child(view)
	view._change_zoom(View.MAX_ZOOM / view._camera.size)
	for frame in range(180):
		await process_frame
	var recorder := Metrics.new()
	recorder.begin("max_zoom_pan", view)
	var last := Time.get_ticks_usec()
	for frame in range(720):
		var t := float(frame) / 719.0
		var target := Vector2(128.0 + sin(t * TAU) * 85.0,
			96.0 + sin(t * TAU * 2.0) * 50.0)
		view._move_center(target - view._center)
		await process_frame
		var now := Time.get_ticks_usec()
		recorder.record(view, float(now - last) / 1000.0)
		last = now
	var report := recorder.finish(view)
	report["zoom"] = view._camera.size
	report["headless"] = DisplayServer.get_name() == "headless"
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--report="):
			var file := FileAccess.open(argument.trim_prefix("--report="), FileAccess.WRITE)
			file.store_string(JSON.stringify(report, "\t"))
	print(JSON.stringify(report))
	view.queue_free()
	await process_frame
	quit()
