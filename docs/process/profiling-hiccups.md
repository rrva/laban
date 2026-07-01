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
