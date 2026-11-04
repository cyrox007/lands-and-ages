# Godot warnings and maximum zoom camera profile

Validated on Windows, Godot 4.7.2, OpenGL Compatibility, GTX 1650.

The 720-frame `world_max_zoom_benchmark.gd` pans a fixed route at zoom 105
after a 180-frame warmup. Run with a real display, not headless:

```
godot --path godot --script res://tests/world_max_zoom_benchmark.gd -- --report=profile.json
```

| Measurement, milliseconds | Before | After |
| --- | ---: | ---: |
| Frame interval median | 6.825 | 6.943 |
| Frame interval p95 | 31.169 | 15.524 |
| Frame interval p99 | 39.554 | 21.699 |
| Maximum frame interval | 74.112 | 31.810 |
| Main-thread chunk build p95 | 37.622 | 17.853 |
| Peak visibility calculation | 13.055 | 14.482 |

Water geometry preparation previously ran synchronously when attaching each
chunk. It now prepares CPU arrays in the same isolated worker as ground
geometry. GPU resource creation remains on the main thread. Hydrology and
surface readiness is ensured before scheduling in every view mode.

These are single local runs, not a guarantee of stable 144 FPS. The fixed-frame
route takes less wall-clock time after optimization: 75 chunks completed versus
97 before, with 46 pending versus 25. This test demonstrates reduced main-thread
stalls but does not establish equal streaming throughput. Visibility and nature
instancing still run on the main thread and remain possible sources of stalls.

Validation: script diagnostics clean before optimization; five existing world,
save, nature, collision and threading smoke tests passed for the warning fixes.
Shoreline geometry and threaded chunk smoke tests passed after moving water
preparation. The threading test additionally compares synchronous and worker
water arrays. JSON nature save restoration has a regression test.
