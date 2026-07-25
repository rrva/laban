# Profiling Hiccups & Workarounds

Field notes for agent-driven Metal System Trace profiling of Laban.

## xctrace "log archive is corrupt or incomplete"

Symptom: `xctrace record` with the **Metal System Trace** template finishes with:

```
Run issues were detected (trace is still ready to be viewed):
* [Error] Data stream: Fatal logging system error: The log archive is corrupt or incomplete and cannot be read
```

Workaround: the `.trace` bundle is still analyzable. `scripts/analyze-metal-trace` exports the time-profile and Metal interval tables without issues. Treat the warning as noise **for the Metal tables only**.

It is not noise for signposts. See the next section.

## The corrupt-log error silently empties every signpost table

This error is not selective. When it fires, the Metal tables are complete and every `os-signpost` table is left as a **schema-only husk with 0 rows**. Nothing warns you at export time: `xctrace export` exits 0 and writes a well-formed file containing no `<row>` elements.

Verified 2026-07-25 on this machine, recording the running app with the correct custom template:

```
xcrun xctrace record --template "Metal with laban signposts" \
  --attach <pid> --time-limit 10s --output run.trace
# -> "Fatal logging system error: The log archive is corrupt or incomplete"

os-signpost         : 0 rows
metal-gpu-intervals : 29708 rows
metal-application-intervals : 212 rows
```

So **`xctrace record` cannot capture Laban's signposts at all**, and the failure looks like "the app emitted nothing" rather than like a recording fault. The template is not the problem: `~/Library/Application Support/Instruments/Templates/Metal with laban signposts.tracetemplate` already contains `com.apple.dt.os-log-signpost-instrument` and pins `dynamicTracingEnabledSubsystems: ["com.rrva.laban.render"]`, which is exactly the subsystem `RenderEncodeSignpost` uses.

To get signposts you must record from the **Instruments GUI in Immediate mode**, then `File > Save As` to a fresh path. Immediate mode is not exposed by the `xctrace` CLI, which is why the CLI path is a dead end. A first save can produce a 0-table husk missing `stores/`; if that happens, re-record rather than trying to repair it.

Always check row counts before trusting a signpost-based analysis:

```sh
xcrun xctrace export --input run.trace \
  --xpath '/trace-toc/run/data/table[@schema="os-signpost"]' --output sp.xml
grep -c '<row>' sp.xml
```

## `.trace` is a bundle, not a file

`rm path.trace` fails because a `.trace` is a directory. Use `rm -rf` or move/replace it as a directory.

## Shader-profiler and GPU-counter schemas can be empty

Even with the Metal System Trace template, `metal-shader-profiler-intervals`, `gpu-shader-profiler-interval`, `gpu-counter-value`, and `metal-gpu-counter-intervals` may contain zero rows. This means:

- You cannot break GPU time down into individual Metal shader functions from the trace alone.
- GPU counters (occupancy, bandwidth, etc.) may not be available depending on OS/device/build settings.

Workaround: rely on `metal-gpu-intervals` for pass-level timing (e.g. `Command Buffer 0:laban.slug.content`) and `metal-application-intervals` / `ca-client-buffer-wait-interval` for frame-pacing diagnosis.

## `analyze-metal-trace` needs `--deep-gpu` for `metal-gpu-intervals`

`metal-gpu-intervals` is not in `DEFAULT_SCHEMAS`, so a plain run gives no per-pass GPU timing for slug/vector passes. It *is* in `DEEP_GPU_SCHEMAS`, so pass `--deep-gpu` rather than exporting by hand:

```sh
./scripts/analyze-metal-trace run.trace --deep-gpu --json-output analysis.json
```

Or export the one table manually:

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

## Recipe: a signpost-correlated GPU trace (Instruments GUI)

This is the only way to get a trace where Laban's own signposts and the Metal GPU timings are both present, so that GPU work can be bucketed by what the renderer thought it was doing. Used to measure the slug damage-band path; the shape generalises to any "why was this frame expensive" question.

`xctrace record` cannot produce this. See the corrupt-log section above.

### 1. Pick the workload first

The comparison is only meaningful if the workload is reproducible and exercises the cases you want to contrast. A live shell tab keeps receiving output, so two recordings are never the same workload. Prefer a fixture session or a frozen command output, and drive motion over the scroll-debug API:

```sh
scripts/restart-app --scroll-debug
curl -fsS -X POST '127.0.0.1:8787/config/renderer?name=slugGlyph'
```

The renderer choice matters: only `slugGlyph` emits `slug.render` signposts and labels its pass `laban.slug.content`. Other backends label passes differently and the analysis will find nothing.

### 2. Record in Immediate mode

1. Open Instruments (`open -a Instruments`, or Xcode > Open Developer Tool).
2. Choose the **"Metal with laban signposts"** user template. It already bundles the `os_signpost` instrument alongside the Metal instruments and pins `dynamicTracingEnabledSubsystems` to `com.rrva.laban.render`. The stock "Metal System Trace" template records **no** signposts.
3. Set the target to the running `LabanApp` process.
4. **File > Recording Options… > Immediate** (default is Deferred). This is the step that makes signposts survive; it has no CLI equivalent.
5. Record, drive the workload, stop.
6. **File > Save As** to a fresh path. Do not overwrite an existing `.trace`.

A `.trace` is a directory, not a file, so remove one with `rm -rf`.

### 3. Verify before analysing

A trace that lost its signposts looks exactly like a trace where the app was idle. Always check:

```sh
xcrun xctrace export --input run.trace \
  --xpath '/trace-toc/run/data/table[@schema="os-signpost"]' --output sp.xml
grep -c '<row>' sp.xml     # 0 means re-record, do not try to salvage
```

If the save produced a husk missing `stores/`, re-record rather than repairing.

### 4. Analyse

```sh
./scripts/analyze-band-gpu-cost run.trace --json band-cost.json
```

It buckets frames by the effective damage shape reported in the `slug.render` end message (`eff=full` / `eff=bands:N`) and reports the GPU duration of the `laban.slug.content` pass per bucket. The script refuses to guess: it exits with an explicit diagnostic when the signpost table is empty, when no `slug.render` spans are present (wrong renderer), or when nothing joins.

### Per-stage GPU time is available; per-shader is not

`metal-gpu-intervals` emits **one row per shader stage per encoder**, with `channel-name` set to `Vertex` or `Fragment`. Rows sharing an `encoder-id` are stages of the same pass, so group them by channel rather than summing: summing across stages double-counts the pass and hides the stage signal. This is usually the signal you actually want, since CPU-side and GPU-side costs often move in opposite directions between rendering strategies.

Do not conclude the column is unavailable from a single trace. A trace recorded without the Metal instruments configured (or one covering mostly other processes) can show `channel-name` only on WindowServer rows, which looks like "not supported for our app" but is a recording artifact.

Finer attribution genuinely is unavailable on this machine: `metal-gpu-counter-intervals`, `gpu-counter-value`, `gpu-shader-profiler-interval` and `metal-shader-profiler-intervals` all export 0 rows, M2 has no GPU counters, and `gpudebug profile run` refuses below M3/A17 Pro. So per-stage totals yes, per-shader no.

### Metal frame capture (`gpucapture`) needs no separate bundle

Frame capture must be armed before the process starts: `gpucapture` cannot attach to a running app, and a bundle without `MetalCaptureEnabled` never appears in `gpucapture list`. `build-app --profile` emits that key, and `install-app` always builds with `--profile`, so **every `install-app` bundle is capturable**. There is no need to `ditto` a copy and re-sign it by hand.

The key is deliberately gated on `--profile` rather than set unconditionally. `--profile` bundles are already dev-only (they retain absolute `/Users/...` paths and must not be distributed), so the capture scaffolding never rides into a shipping bundle.

Two consequences worth remembering:

- Do not keep a second hand-made capture bundle around. It shares `CFBundleIdentifier` with the real one, so the two contend for the single-instance lock, and both carry the same `LABANBuildCommit`, which means the build stamp cannot tell you which is running. Disambiguate by bundle path in `ps`.
- The key keeps Metal's capture scaffolding resident for the process lifetime. Treat GPU timings from a capture-enabled bundle as comparable to each other, not to a shipping build.

### Reading the `xctrace export` XML

Two encoding details will silently corrupt any hand-rolled parser:

- **Back-references.** A value appears once as `<tag id="12" fmt="…">text</tag>`; every later use is `<tag ref="12"/>` with no content. Resolve `ref`, or every row after the first parses as null. Keep the raw text and the `fmt` separately: numeric columns need the text (`start-time` text is nanoseconds, its `fmt` is a formatted clock string) while container columns like `<thread>` carry their name only in `fmt`.
- **`<sentinel/>` means an absent column** but still occupies a column slot. Skip it when aligning row children against the schema's `<col>` list and every column after the first null shifts by one.

`scripts/analyze-band-gpu-cost` has a `parse_table` that handles both and streams with `iterparse` (a full DOM parse of a 30 MB export takes minutes; streaming takes seconds).

## In-process CPU sampling vs GPU tracing

Laban has two complementary profilers. Pick by what you are measuring.

- Use the in-process sampling profiler (swift-profile-recorder; enable via the
  Settings toggle / `--profile-recorder` / `PROFILE_RECORDER_SERVER_URL[_PATTERN]`,
  capture with Debug → Capture CPU Profile… or Start CPU Recording) for CPU and
  host-side work: main-thread hotspots, cell/glyph build, PTY drain, and off-CPU
  waits (locks, sleeps, blocking syscalls — it records waiting threads too). It
  needs no ptrace privileges. `Package.swift` allows only the documented
  `https://github.com/apple/swift-profile-recorder.git` dependency, pinned by
  `Package.resolved` at version `0.3.18` / revision
  `e110ba85da7d43a47b0e964726e84fddcf720192`.
- Use a Metal System Trace (see the scroll-jank sections above) for GPU work:
  render/compute passes, shader cost, GPU counters, and present timing. The
  in-process sampler cannot see GPU execution; it only sees the CPU side that
  encodes and submits.

Rule of thumb: if the question is "which Swift/C function is burning CPU or
blocking?", sample in-process; if it is "which pass/shader is slow on the GPU?",
take a Metal System Trace.

## Sampler baseline overhead

Enabling CPU profile capture is now only a gate: Laban opens no profiler socket,
starts no listener, and does no sampling while idle. During a capture, the
sampler and CoreSymbolication work are part of the measured process and can
appear in the profile. Compare against an idle baseline captured with the same
sample count and interval, and focus on the application threads or delta that
motivated the measurement.

The older `ProfileRecorderServer` integration was removed after a recoverable
Darwin accept error could end its async accept sequence while leaving the
listening channel alive. The next connection then destroyed an undelivered
`NIOAsyncChannel` child with an unfinished writer and trapped the app. See
`docs/upstream/swift-profile-recorder-recoverable-accept-error-crash.md` for the
upstream-ready report and source-level analysis.

The installed transparency compositor still needs a CPU profile alongside its
Metal trace. It now starts the bounded `captureProfile` diagnostic control
action asynchronously with the fixture-only whole-app token it already owns,
so CPU sampling, Metal tracing, and host CPU measurements overlap without
restoring a profiler listener. The action is not exposed through session-scoped
lazy attach because a profile contains stacks from the whole app process.
