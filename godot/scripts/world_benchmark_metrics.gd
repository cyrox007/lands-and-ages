extends RefCounted
## Измерения только графического маршрута: без смешивания с физикой мира.
## Интервалы кадров в headless — не реальные FPS видеокарты.

const RenderCache = preload("res://scripts/chunk_render_cache.gd")

var _name := ""
var _frames: Array[float] = []
var _build_frames: Array[float] = []
var _prepare_before := 0
var _upload_before := 0
var _builds_before := 0
var _ground_before := 0
var _water_before := 0
var _last_build_count := 0
var _hits_before := 0
var _evictions_before := 0
var _skipped_before := 0
var _visibility_before := 0
var _fast_rejects_before := 0
var _precise_checks_before := 0
var _last_visibility_count := 0
var _peak_visibility_ms := 0.0
var _peak_active := 0
var _peak_pending := 0
var _peak_cache_bytes := 0
var _peak_static_bytes := 0
var _cache_limits_valid := true


static func percentile(values: Array[float], ratio: float) -> float:
	if values.is_empty():
		return 0.0
	var ordered := values.duplicate()
	ordered.sort()
	var index := clampi(ceili(float(ordered.size()) *
		clampf(ratio, 0.0, 1.0)) - 1, 0, ordered.size() - 1)
	return ordered[index]


func begin(name: String, view: Node3D) -> void:
	_name = name
	_frames.clear()
	_build_frames.clear()
	_prepare_before = view._total_ground_prepare_us
	_upload_before = view._total_ground_upload_us
	_builds_before = view._chunk_rebuilds
	_ground_before = view._total_ground_build_us
	_water_before = view._total_water_build_us
	_last_build_count = _builds_before
	_hits_before = view._render_cache.hits
	_evictions_before = view._render_cache.evictions
	_skipped_before = view._skipped_stale_jobs
	_visibility_before = view._visibility_refreshes
	_fast_rejects_before = view._visibility_fast_rejects
	_precise_checks_before = view._visibility_precise_checks
	_last_visibility_count = _visibility_before
	_peak_visibility_ms = 0.0
	_peak_active = 0
	_peak_pending = 0
	_peak_cache_bytes = 0
	_peak_static_bytes = 0
	_cache_limits_valid = true


func record(view: Node3D, frame_interval_ms: float) -> void:
	_frames.append(frame_interval_ms)
	if view._chunk_rebuilds > _last_build_count:
		_build_frames.append(float(view._last_chunk_build_us) / 1000.0)
	_last_build_count = view._chunk_rebuilds
	if view._visibility_refreshes > _last_visibility_count:
		_peak_visibility_ms = maxf(_peak_visibility_ms,
			float(view._last_visibility_us) / 1000.0)
	_last_visibility_count = view._visibility_refreshes
	_peak_active = maxi(_peak_active, view._active.size())
	_peak_pending = maxi(_peak_pending,
		view._pending.size() + view._chunk_jobs.size())
	_peak_cache_bytes = maxi(_peak_cache_bytes, view._render_cache.estimated_bytes)
	_peak_static_bytes = maxi(_peak_static_bytes,
		int(Performance.get_monitor(Performance.MEMORY_STATIC)))
	if view._render_cache.count() > RenderCache.MAX_CHUNKS or \
			view._render_cache.estimated_bytes > RenderCache.MAX_ESTIMATED_BYTES:
		_cache_limits_valid = false


func finish(view: Node3D) -> Dictionary:
	return {
		"name": _name,
		"frames": _frames.size(),
		"interval_ms": {
			"p50": percentile(_frames, 0.50),
			"p95": percentile(_frames, 0.95),
			"p99": percentile(_frames, 0.99),
			"max": percentile(_frames, 1.0)
		},
		"build_frame_ms": {
			"count": _build_frames.size(),
			"p50": percentile(_build_frames, 0.50),
			"p95": percentile(_build_frames, 0.95),
			"max": percentile(_build_frames, 1.0)
		},
		"chunks_built": view._chunk_rebuilds - _builds_before,
		"ground_prepare_worker_ms_total": float(
			view._total_ground_prepare_us - _prepare_before) / 1000.0,
		"ground_upload_main_ms_total": float(
			view._total_ground_upload_us - _upload_before) / 1000.0,
		"ground_mesh_cpu_ms_total": float(view._total_ground_build_us -
			_ground_before) / 1000.0,
		"water_mesh_cpu_ms_total": float(view._total_water_build_us -
			_water_before) / 1000.0,
		"cache_hits": view._render_cache.hits - _hits_before,
		"cache_evictions": view._render_cache.evictions - _evictions_before,
		"stale_jobs_skipped": view._skipped_stale_jobs - _skipped_before,
		"visibility_refreshes": view._visibility_refreshes - _visibility_before,
		"visibility_fast_rejects": view._visibility_fast_rejects - _fast_rejects_before,
		"visibility_precise_checks": view._visibility_precise_checks - _precise_checks_before,
		"peak_visibility_ms": _peak_visibility_ms,
		"peak_visible_chunks": _peak_active,
		"peak_pending_chunks": _peak_pending,
		"peak_cached_geometry_bytes": _peak_cache_bytes,
		"peak_godot_static_bytes": _peak_static_bytes,
		"cache_limits_valid": _cache_limits_valid,
		"pending_at_end": view._pending.size() + view._chunk_jobs.size()
	}
