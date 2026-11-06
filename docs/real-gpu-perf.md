# Real-GPU performance run — 2026-11-06

The shell's perf budgets (`shani-shell/dev/shell-test.sh`, `dev/check.sh perf`)
are calibrated for the container's software rendering. This run repeats them
with the host GPU passed through, to measure what a real user gets.

## How

```sh
docker run --rm --device=/dev/dri --cap-add SYS_PTRACE \
  -v ~/Documents/shani/shani-shell:/work \
  -v ~/Documents/shani/shani-testbed:/testbed:ro \
  -e SHELL_TEST_ONLY=perf shani-shell-dev sh /work/dev/shell-test.sh
```

Host GPU: Intel TigerLake-LP GT2 (Iris Xe), `/dev/dri/card1` + `renderD128`.
Software-rendering budgets are kept (not loosened): a GPU should cost less.

## Result (2026-11-06, Iris Xe)

| Check | Measured | Budget | |
|---|---|---|---|
| idle frames | 3 frames / 15 s, 2 windows | 6 | PASS |
| idle memory | 512 MB RSS | 520 MB | PASS |
| open speed | launcher 301 ms, sidebar 197 ms | 600 ms | PASS |
| no leak | −6 MB floor over 11 rounds | +24 MB | PASS |
| startup | 1858 ms to first answer | 3500 ms | PASS |
| idle cost | 8 programs/min, CPU 2 ms/s | — | PASS |

## Caveat

`shell-loads-clean` FAILs in this environment only because Qt's scenegraph
probes Vulkan and the container has no Vulkan ICD for the Iris Xe
(`MESA: error: ZINK: vkCreateInstance failed`), which lands in qs.log.
GL rendering uses the real GPU via `/dev/dri`. The probe error is
environmental, not a shell defect; it disappears where a Vulkan ICD exists.
