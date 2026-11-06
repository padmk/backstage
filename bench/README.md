# Benchmark

Latency through the installed command and app, against the fixture app in the background. It needs the app installed with Accessibility (`make install`), and puts the fixture on the app list for the run.

```sh
make bench                                  # 30 rounds
BENCH=1 BENCH_ROUNDS=100 swift test --filter BenchTests
```

Result on 2026-11-06, macOS 27.2, Apple M4 Pro, 30 rounds, two runs:

| Measure | p50 | p95 |
|---|---|---|
| First read of the session | 40 to 62 ms | |
| `list_apps` | 8.6 to 10.6 ms | 16.1 to 17.7 ms |
| `get_window_state` (about 25 elements) | 15.6 to 15.7 ms | 22.1 to 26.8 ms |
| `press` with state report | 627 to 635 ms | 754 to 809 ms |
| `screenshot` | 66.5 ms | 133 to 228 ms |

Starting the MCP command, answering `initialize` and ending takes about 20 ms, with a peak of 8.6 MB of memory.

`press` includes waiting until the window has stayed the same for 0.3 s after the change shows. Real apps have far larger trees, so their reads take longer. The first read excludes building the app.
