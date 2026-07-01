# Profiling Hiccups & Workarounds

Field notes for agent-driven Metal System Trace profiling of Laban.

## xctrace "log archive is corrupt or incomplete"

Symptom: `xctrace record` with the **Metal System Trace** template finishes with:

```
Run issues were detected (trace is still ready to be viewed):
* [Error] Data stream: Fatal logging system error: The log archive is corrupt or incomplete and cannot be read
```

Workaround: the `.trace` bundle is still analyzable. `scripts/analyze-metal-trace` exports the time-profile and Metal interval tables without issues. Treat the warning as noise unless the exported tables themselves are empty.

## `.trace` is a bundle, not a file

`rm path.trace` fails because a `.trace` is a directory. Use `rm -rf` or move/replace it as a directory.

## Shader-profiler and GPU-counter schemas can be empty

Even with the Metal System Trace template, `metal-shader-profiler-intervals`, `gpu-shader-profiler-interval`, `gpu-counter-value`, and `metal-gpu-counter-intervals` may contain zero rows. This means:

- You cannot break GPU time down into individual Metal shader functions from the trace alone.
- GPU counters (occupancy, bandwidth, etc.) may not be available depending on OS/device/build settings.

Workaround: rely on `metal-gpu-intervals` for pass-level timing (e.g. `Command Buffer 0:laban.slug.content`) and `metal-application-intervals` / `ca-client-buffer-wait-interval` for frame-pacing diagnosis.

## `analyze-metal-trace` does not export `metal-gpu-intervals`

The default schema list in `scripts/analyze-metal-trace` does not include `metal-gpu-intervals`, so you do not get per-pass GPU timing for slug/vector passes from the script alone.

Workaround: export manually and parse the durations:

```sh
xcrun xctrace export --input run.trace \
  --xpath '/trace-toc/run/data/table[@schema="metal-gpu-intervals"]' \
  --output metal-gpu-intervals.xml
```

Labels look like `Command Buffer 0:laban.slug.content      ( LabanApp (pid) )  ...`.

## Live-shell tabs change between recordings

A normal-buffer shell tab keeps receiving output while you profile. Scrollback totals and buffer contents shift, so two recordings of the "same" tab are not identical workloads. This can change frame-time distributions and GPU-pass timings between runs. For reproducible comparisons, use a fixture/headless session or a frozen command output.

## Scroll-debug tab selection is zero-based

`POST /config/tab?index=1` selects the **second** tab. This is documented in the scroll-debug help text but is easy to misremember when a user says "tab 2".

## How to measure scroll jank

Goal: drive heavy smooth scroll and read the built-in jank counters until they show 0%.

### 1. Launch with scroll-debug

```sh
scripts/restart-app --scroll-debug
```

Wait for `http://127.0.0.1:8787/scroll/state` to respond.

### 2. Pick a normal-buffer tab with deep scrollback

The scroll-debug API is zero-based. Tab 2 = `index=1`.

```sh
curl -fsS -X POST 'http://127.0.0.1:8787/config/tab?index=1'
curl -fsS http://127.0.0.1:8787/scroll/state | python3 -c '
import sys, json
d = json.load(sys.stdin)["view"]
print(f"rows={d[\"total\"]} vp={d[\"vp\"]} alt={d[\"alt\"]}")
'
```

You want `alt=false` and `total` much larger than `vp` (e.g. >1000 rows). An alt-screen TUI has no scrollback, so the burst is a no-op.

### 3. Select the renderer under test

```sh
curl -fsS -X POST 'http://127.0.0.1:8787/config/renderer?name=gpuDriven'
# or: slugGlyph, vectorGlyph, classic
curl -fsS http://127.0.0.1:8787/zoom/state | grep backend
```

### 4. Reset the rings

```sh
curl -fsS 'http://127.0.0.1:8787/scroll/frame-stats?reset=1' >/dev/null
curl -fsS 'http://127.0.0.1:8787/scroll/present-stats?reset=1' >/dev/null
```

### 5. Drive heavy smooth scroll

This produces continuous sub-cell motion so the PD controller stays animated:

```sh
for i in $(seq 1 120); do
  curl -fsS -X POST 'http://127.0.0.1:8787/scroll/smooth?rows=-5&velocity=-60' >/dev/null
  sleep 0.04
  curl -fsS -X POST 'http://127.0.0.1:8787/scroll/smooth?rows=5&velocity=60' >/dev/null
  sleep 0.04
done
```

Run it for at least 10 s (the loop above is ~10 s). Do not move the mouse or switch apps while it runs.

### 6. Read the counters

```sh
echo "=== display-link TICK jank ==="
curl -fsS http://127.0.0.1:8787/scroll/frame-stats

echo "=== actual PRESENT jank ==="
curl -fsS http://127.0.0.1:8787/scroll/present-stats
```

Key fields:
- `fps` should be ~120 on ProMotion.
- `jankFrames` / `jankPercent` is what you are trying to drive to 0.
- `maxMs` and `p99Ms` show the tail.

### 7. Distinguish tick jank from present jank

- `frame-stats` measures the **display-link tick interval**. It can be perfect even if the frame never reached the screen.
- `present-stats` measures **actual presented-frame intervals** from the `CAMetalDisplayLink` callback. This is the ground truth.

If `frame-stats` is 0% but `present-stats` is >0%, the content pipeline is fine and the problem is in the present/blit path (drawable pacing, present-link scheduling, or GPU work delaying the blit).

### 8. Capture a Metal System Trace for the outlier frames

Record while repeating the scroll burst:

```sh
xcrun xctrace record --template "Metal System Trace" \
  --time-limit 15s --output run.trace --attach Laban
```

Analyze with:

```sh
./scripts/analyze-metal-trace run.trace --json-output analysis.json
```

Pay attention to:
- `cpu.categoryHits`: CPU bottleneck (often glyph-atlas/font lookup).
- `ca-client-buffer-wait-interval`: CPU waiting for drawable.
- Manually export `metal-gpu-intervals` for renderer-specific GPU pass timing.

### 9. Iterate toward 0%

Common levers:
- Reduce glyph-atlas/font-lookup CPU variance (prepopulate glyphs in scroll direction, batch uploads).
- Decouple GPU glyph-bake work from the present command buffer (`vector-drawable-pacing-120hz.md` Milestone 3).
- Ensure `LabanVectorPresentDisplayLink` is not disabled.
- Use a fixture session instead of a live shell for reproducible comparisons.
