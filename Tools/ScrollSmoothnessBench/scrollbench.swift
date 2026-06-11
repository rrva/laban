// scrollbench — on-glass scroll smoothness harness.
//
// Captures a target window via ScreenCaptureKit while injecting synthetic
// continuous (pixel) scroll-wheel events at a constant velocity, then measures
// the vertical pixel displacement between consecutive delivered frames.
// Because ScreenCaptureKit only delivers frames when the composited window
// content actually changed, the delivery timeline + displacement series is a
// direct, app-agnostic record of what hit the glass:
//
//   - slots-per-frame distribution  -> dropped/repeated frames (stutter)
//   - stddev of displacement/slot   -> judder (uneven content velocity)
//   - max single-frame jump         -> worst hitch
//   - hitch ms/s                    -> Apple-style "late frame time" per second
//
// Works identically against any app (Chrome, Laban, ...), so results are
// directly comparable.
//
// Build: xcrun swiftc -O -parse-as-library scrollbench.swift -o scrollbench
//
// TCC: the *hosting terminal app* needs Screen Recording (for capture) and
// Accessibility (to post CGEvents). First run prompts.
//
// Displacement is estimated by minimising SAD between per-row luminance
// profiles of consecutive frames. Caveat: repeating page content must have a
// vertical period larger than the shift search range (the ps-ef test page
// repeats every ~1500 physical px; search range stays well under that).

import AppKit
import CoreMedia
import QuartzCore
import ScreenCaptureKit

// MARK: - CLI

struct Config {
    var app = ""
    var title: String?
    var duration = 6.0
    var velocity = 1500.0  // logical px/s
    var eventHz = 120.0
    var fps = 0  // 0 = display refresh
    var directionUp = false
    var bandTop = 0.25
    var bandBottom = 0.95
    var outDir: String?
    var list = false
    var flick = false
}

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data(("scrollbench: " + msg + "\n").utf8))
    exit(1)
}

func parseArgs() -> Config {
    var c = Config()
    var args = Array(CommandLine.arguments.dropFirst())
    func next(_ flag: String) -> String {
        if args.isEmpty { die("missing value for \(flag)") }
        return args.removeFirst()
    }
    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "--app": c.app = next(a)
        case "--title": c.title = next(a)
        case "--duration": c.duration = Double(next(a)) ?? c.duration
        case "--velocity": c.velocity = Double(next(a)) ?? c.velocity
        case "--event-hz": c.eventHz = Double(next(a)) ?? c.eventHz
        case "--fps": c.fps = Int(next(a)) ?? 0
        case "--direction": c.directionUp = next(a).lowercased() == "up"
        case "--band-top": c.bandTop = Double(next(a)) ?? c.bandTop
        case "--band-bottom": c.bandBottom = Double(next(a)) ?? c.bandBottom
        case "--out": c.outDir = next(a)
        case "--list": c.list = true
        case "--flick": c.flick = true
        case "-h", "--help":
            print(
                """
                usage: scrollbench --app <name substring> [options]
                  --list                  list candidate windows and exit
                  --title <substring>     disambiguate by window title
                  --duration <s>          scroll duration (default 6)
                  --velocity <px/s>       logical scroll speed (default 1500)
                  --direction up|down     scroll direction (default down; use up for terminal scrollback)
                  --event-hz <hz>         injection rate (default 120)
                  --fps <n>               capture fps (default: display refresh)
                  --band-top <f>          analysis band top, fraction of height (default 0.25, skips browser chrome)
                  --band-bottom <f>       analysis band bottom (default 0.95)
                  --out <dir>             artifact directory (default /tmp/scrollbench/<app>-<ts>)
                  --flick                 emulate a trackpad flick: phased gesture (0.4s at
                                          --velocity) then momentum events decaying exp(t/0.65s),
                                          with scroll/momentum phase fields set. Prints the
                                          tail displacement series to spot end-of-gesture jank.
                """)
            exit(0)
        default: die("unknown arg \(a) (try --help)")
        }
    }
    if !c.list && c.app.isEmpty { die("--app is required (try --list)") }
    return c
}

// MARK: - Frame collection

final class Collector: NSObject, SCStreamOutput {
    struct Sample {
        let t: Double  // host-clock seconds (comparable with CACurrentMediaTime)
        let profile: [Float]
    }
    private(set) var samples: [Sample] = []
    let queue = DispatchQueue(label: "scrollbench.collector", qos: .userInteractive)

    func stream(
        _ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType
    ) {
        guard type == .screen, sb.isValid,
            let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let raw = atts.first?[.status] as? Int,
            SCFrameStatus(rawValue: raw) == .complete,
            let pb = CMSampleBufferGetImageBuffer(sb)
        else { return }
        let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
        if let prof = Self.rowProfile(pb) {
            samples.append(Sample(t: t, profile: prof))
        }
    }

    // Per-row luminance proxy (green channel, central 60% width, every 4th px).
    // Central band excludes scrollbars at the window edges.
    static func rowProfile(_ pb: CVPixelBuffer) -> [Float]? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let x0 = w / 5, x1 = w * 4 / 5
        guard w > 16, h > 16 else { return nil }
        var prof = [Float](repeating: 0, count: h)
        let p = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            let row = p + y * stride
            var acc = 0
            var x = x0
            while x < x1 {
                acc += Int(row[x * 4 + 1])
                x += 4
            }
            prof[y] = Float(acc)
        }
        return prof
    }
}

// MARK: - Scroll injection

func injectScroll(durationS: Double, velocityPxPerS: Double, eventHz: Double, sign: Int32, at location: CGPoint) {
    let src = CGEventSource(stateID: .hidSystemState)
    let deltaPerEvent = velocityPxPerS / eventHz
    let n = Int(durationS * eventHz)
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    func ticks(_ s: Double) -> UInt64 {
        UInt64(s * 1e9 * Double(tb.denom) / Double(tb.numer))
    }
    let start = mach_absolute_time()
    var acc = 0.0
    for i in 0..<n {
        mach_wait_until(start &+ ticks(Double(i) / eventHz))
        acc += deltaPerEvent
        let d = Int32(acc.rounded())
        acc -= Double(d)
        guard d != 0 else { continue }
        if let ev = CGEvent(
            scrollWheelEvent2Source: src, units: .pixel, wheelCount: 1,
            wheel1: sign * d, wheel2: 0, wheel3: 0)
        {
            ev.location = location
            ev.post(tap: .cghidEventTap)
        }
    }
}

/// Emulate a real trackpad flick: a phased finger-down gesture at constant
/// velocity, phase-ended, then a momentum stream with exponentially decaying
/// deltas and proper momentum phase markers. Returns (gestureEnd, momentumEnd)
/// offsets in seconds from the first event, so the analysis can localize
/// end-of-gesture artifacts.
func injectFlick(
    velocityPxPerS: Double, eventHz: Double, sign: Int32, at location: CGPoint
) -> (gestureEndS: Double, momentumEndS: Double) {
    let src = CGEventSource(stateID: .hidSystemState)
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    func ticks(_ s: Double) -> UInt64 {
        UInt64(s * 1e9 * Double(tb.denom) / Double(tb.numer))
    }
    let start = mach_absolute_time()
    let dt = 1.0 / eventHz
    var acc = 0.0
    var i = 0
    // CGScrollPhase: began=1 changed=2 ended=4; CGMomentumScrollPhase: begin=1 continue=2 end=3.
    func post(_ deltaPx: Double, scrollPhase: Int64, momentumPhase: Int64) {
        mach_wait_until(start &+ ticks(Double(i) * dt))
        i += 1
        acc += deltaPx
        let d = Int32(acc.rounded())
        acc -= Double(d)
        guard
            let ev = CGEvent(
                scrollWheelEvent2Source: src, units: .pixel, wheelCount: 1,
                wheel1: sign * d, wheel2: 0, wheel3: 0)
        else { return }
        ev.location = location
        ev.setIntegerValueField(.scrollWheelEventScrollPhase, value: scrollPhase)
        ev.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
        ev.post(tap: .cghidEventTap)
    }

    let gestureEvents = max(2, Int(0.4 * eventHz))
    let deltaPerEvent = velocityPxPerS / eventHz
    post(deltaPerEvent, scrollPhase: 1, momentumPhase: 0)
    for _ in 1..<gestureEvents {
        post(deltaPerEvent, scrollPhase: 2, momentumPhase: 0)
    }
    post(0, scrollPhase: 4, momentumPhase: 0)
    let gestureEnd = Double(i) * dt

    // The WindowServer applies the natural-scroll inversion to the momentum
    // phase of synthetic scroll events but not to the gesture phase
    // (observed empirically: gesture deltas arrive as posted, momentum
    // deltas arrive sign-flipped). Pre-invert so the target app receives a
    // directionally consistent flick.
    var v = velocityPxPerS
    var first = true
    while v > 30 {
        post(-v / eventHz, scrollPhase: 0, momentumPhase: first ? 1 : 2)
        first = false
        v *= exp(-dt / 0.65)
    }
    post(0, scrollPhase: 0, momentumPhase: 3)
    return (gestureEnd, Double(i) * dt)
}

// MARK: - Analysis

struct PairStat {
    let t: Double
    let dt: Double
    let slots: Int
    let disp: Int  // signed physical px
}

func displacement(prev: [Float], cur: [Float], yTop: Int, yBot: Int, maxShift: Int) -> Int {
    let n = min(prev.count, cur.count)
    var sads = [Float](repeating: .greatestFiniteMagnitude, count: 2 * maxShift + 1)
    var bestSAD = Float.greatestFiniteMagnitude
    var s = -maxShift
    while s <= maxShift {
        var sad: Float = 0
        var cnt = 0
        var y = yTop
        while y < yBot {
            let yp = y + s
            if yp >= 0 && yp < n {
                sad += abs(prev[yp] - cur[y])
                cnt += 1
            }
            y += 2
        }
        if cnt > 50 {
            let norm = sad / Float(cnt)
            sads[s + maxShift] = norm
            if norm < bestSAD { bestSAD = norm }
        }
        s += 1
    }
    // Tie-break toward the smallest |shift|: repetitive text (e.g. similar
    // adjacent ps-output rows) produces near-equal SAD minima at whole-row
    // multiples; without this, sub-pixel true motion can read as phantom
    // ±N-row jumps.
    let threshold = bestSAD * 1.02 + 1e-3
    var bestS = Int.max
    for (idx, v) in sads.enumerated() where v <= threshold {
        let shift = idx - maxShift
        if bestS == Int.max || abs(shift) < abs(bestS) { bestS = shift }
    }
    return bestS == Int.max ? 0 : bestS
}

func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let idx = min(sorted.count - 1, Int(Double(sorted.count) * p))
    return sorted[idx]
}

// MARK: - Main

@main
struct Scrollbench {
    static func main() async {
        let cfg = parseArgs()

        // Permissions preflight.
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            die(
                "no Screen Recording permission. Grant it to your terminal app in System Settings > Privacy & Security > Screen Recording, then re-run."
            )
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
        } catch {
            die("SCShareableContent failed: \(error.localizedDescription)")
        }

        let candidates = content.windows.filter { w in
            guard let app = w.owningApplication else { return false }
            return w.isOnScreen && w.frame.height > 200 && w.frame.width > 200
                && !app.applicationName.isEmpty
        }

        if cfg.list {
            for w in candidates {
                let app = w.owningApplication!
                print(
                    "\(app.applicationName) [pid \(app.processID)]  \"\(w.title ?? "")\"  \(Int(w.frame.width))x\(Int(w.frame.height))"
                )
            }
            exit(0)
        }

        guard
            let win = candidates.first(where: { w in
                let nameOK = w.owningApplication!.applicationName
                    .localizedCaseInsensitiveContains(cfg.app)
                let titleOK =
                    cfg.title.map { (w.title ?? "").localizedCaseInsensitiveContains($0) } ?? true
                return nameOK && titleOK
            })
        else {
            die("no window matching --app \"\(cfg.app)\" (try --list)")
        }
        let scApp = win.owningApplication!

        // Accessibility needed to post scroll events.
        let axOpts =
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(axOpts) {
            die(
                "no Accessibility permission (needed to inject scroll events). Grant it to your terminal app in System Settings > Privacy & Security > Accessibility, then re-run."
            )
        }

        // Display timing.
        var refresh = CGDisplayCopyDisplayMode(CGMainDisplayID())?.refreshRate ?? 0
        if refresh < 1 { refresh = Double(NSScreen.main?.maximumFramesPerSecond ?? 60) }
        let captureFps = cfg.fps > 0 ? cfg.fps : Int(refresh.rounded())

        // Bring target frontmost, park the cursor over it.
        NSRunningApplication(processIdentifier: pid_t(scApp.processID))?.activate()
        let center = CGPoint(x: win.frame.midX, y: win.frame.midY)
        CGWarpMouseCursorPosition(center)
        try? await Task.sleep(nanoseconds: 500_000_000)

        // Capture setup.
        let filter = SCContentFilter(desktopIndependentWindow: win)
        var scale = 2.0
        if #available(macOS 14.0, *) { scale = Double(filter.pointPixelScale) }
        let streamCfg = SCStreamConfiguration()
        streamCfg.width = Int(win.frame.width * scale)
        streamCfg.height = Int(win.frame.height * scale)
        streamCfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(captureFps))
        streamCfg.pixelFormat = kCVPixelFormatType_32BGRA
        streamCfg.showsCursor = false
        streamCfg.queueDepth = 8

        let collector = Collector()
        let stream = SCStream(filter: filter, configuration: streamCfg, delegate: nil)
        do {
            try stream.addStreamOutput(collector, type: .screen, sampleHandlerQueue: collector.queue)
            try await stream.startCapture()
        } catch {
            die("capture failed: \(error.localizedDescription)")
        }

        let velocityPhys = cfg.velocity * scale
        print(
            "target: \(scApp.applicationName) — \"\(win.title ?? "")\" \(Int(win.frame.width))x\(Int(win.frame.height)) @\(Int(scale))x"
        )
        print(
            "display: \(Int(refresh)) Hz, capture \(captureFps) fps  |  scrolling \(cfg.directionUp ? "up" : "down") \(Int(cfg.velocity)) px/s for \(cfg.duration)s — hands off the mouse/keyboard"
        )

        try? await Task.sleep(nanoseconds: 800_000_000)  // capture warm-up

        final class FlickMarkers {
            var value: (gestureEndS: Double, momentumEndS: Double)?
        }
        let flickMarkers = FlickMarkers()
        let tInjStart = CACurrentMediaTime()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let th = Thread {
                if cfg.flick {
                    flickMarkers.value = injectFlick(
                        velocityPxPerS: cfg.velocity, eventHz: cfg.eventHz,
                        sign: cfg.directionUp ? 1 : -1, at: center)
                } else {
                    injectScroll(
                        durationS: cfg.duration, velocityPxPerS: cfg.velocity, eventHz: cfg.eventHz,
                        sign: cfg.directionUp ? 1 : -1, at: center)
                }
                cont.resume()
            }
            th.qualityOfService = .userInteractive
            th.start()
        }
        let tInjEnd = CACurrentMediaTime()

        try? await Task.sleep(nanoseconds: 500_000_000)
        try? await stream.stopCapture()
        collector.queue.sync {}

        // Analysis window: skip ramp-in/out. A flick wants the whole gesture
        // including the momentum tail and the post-input settle.
        let w0 = cfg.flick ? tInjStart + 0.05 : tInjStart + 0.3
        let w1 = cfg.flick ? tInjEnd + 0.45 : tInjEnd - 0.1
        let samples = collector.samples
        guard samples.count > 10 else {
            die("only \(samples.count) frames captured — is the window visible and unoccluded?")
        }
        let profH = samples[0].profile.count
        let yTop = Int(cfg.bandTop * Double(profH))
        let yBot = Int(cfg.bandBottom * Double(profH))
        let slotDur = 1.0 / refresh
        let maxShift = min(Int(velocityPhys * slotDur * 16) + 60, Int(Double(profH) * 0.4))

        var pairs: [PairStat] = []
        for i in 1..<samples.count {
            let a = samples[i - 1]
            let b = samples[i]
            guard a.t >= w0, b.t <= w1 else { continue }
            let dt = b.t - a.t
            let slots = max(1, Int((dt / slotDur).rounded()))
            let d = displacement(
                prev: a.profile, cur: b.profile, yTop: yTop, yBot: yBot, maxShift: maxShift)
            pairs.append(PairStat(t: b.t, dt: dt, slots: slots, disp: d))
        }
        guard pairs.count > 10 else {
            die("only \(pairs.count) frame pairs inside the scroll window — capture too sparse")
        }

        let span = pairs.last!.t - pairs.first!.t + pairs.first!.dt
        let moving = pairs.filter { $0.disp != 0 }
        let zeroFrames = pairs.count - moving.count
        let totalSlots = pairs.reduce(0) { $0 + $1.slots }
        let missedSlots = pairs.reduce(0) { $0 + ($1.slots - 1) }
        let hitchMsPerS = Double(missedSlots) * slotDur / span * 1000.0
        var slotHist: [Int: Int] = [:]
        for p in pairs { slotHist[p.slots, default: 0] += 1 }

        let dps = moving.map { Double(abs($0.disp)) / Double($0.slots) }.sorted()
        let dpsMean = dps.reduce(0, +) / Double(max(1, dps.count))
        let dpsVar = dps.reduce(0) { $0 + ($1 - dpsMean) * ($1 - dpsMean) } / Double(max(1, dps.count))
        let dpsStd = dpsVar.squareRoot()
        let maxJump = pairs.map { abs($0.disp) }.max() ?? 0
        let clipped = pairs.filter { abs($0.disp) >= maxShift }.count
        let measuredVel = pairs.reduce(0.0) { $0 + Double(abs($1.disp)) } / span

        // Artifacts.
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let safeApp = cfg.app.replacingOccurrences(of: " ", with: "-").lowercased()
        let outDir = cfg.outDir ?? "/tmp/scrollbench/\(safeApp)-\(fmt.string(from: Date()))"
        try? FileManager.default.createDirectory(
            atPath: outDir, withIntermediateDirectories: true)
        var csv = "t,dt_ms,slots,disp_px\n"
        for p in pairs {
            csv += String(format: "%.6f,%.3f,%d,%d\n", p.t - tInjStart, p.dt * 1000, p.slots, p.disp)
        }
        try? csv.write(toFile: outDir + "/frames.csv", atomically: true, encoding: .utf8)

        let report: [String: Any] = [
            "app": scApp.applicationName,
            "windowTitle": win.title ?? "",
            "refreshHz": refresh,
            "captureFps": captureFps,
            "scale": scale,
            "commandedVelocityPhysPxPerS": velocityPhys,
            "measuredVelocityPhysPxPerS": (measuredVel * 10).rounded() / 10,
            "analyzedSeconds": (span * 100).rounded() / 100,
            "framePairs": pairs.count,
            "slotHistogram": Dictionary(uniqueKeysWithValues: slotHist.map { (String($0.key), $0.value) }),
            "missedSlotRatio": (Double(missedSlots) / Double(totalSlots) * 1000).rounded() / 1000,
            "hitchMsPerSecond": (hitchMsPerS * 100).rounded() / 100,
            "dispPerSlot": [
                "meanPx": (dpsMean * 10).rounded() / 10,
                "stddevPx": (dpsStd * 100).rounded() / 100,
                "p99Px": percentile(dps, 0.99),
            ],
            "zeroMotionFrames": zeroFrames,
            "maxSingleFrameJumpPx": maxJump,
            "clippedMeasurements": clipped,
        ]
        if let data = try? JSONSerialization.data(
            withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        {
            try? data.write(to: URL(fileURLWithPath: outDir + "/report.json"))
        }

        // Summary.
        let hist = slotHist.sorted { $0.key < $1.key }
            .map { "\($0.key)x:\($0.value)" }.joined(separator: "  ")
        print("")
        print("frames analyzed: \(pairs.count) pairs over \(String(format: "%.2f", span))s")
        print("slot distribution (vsyncs between frames): \(hist)")
        print(
            "missed-slot ratio: \(String(format: "%.1f", Double(missedSlots) / Double(totalSlots) * 100))%  |  hitch time: \(String(format: "%.1f", hitchMsPerS)) ms/s"
        )
        print(
            "displacement/slot: mean \(String(format: "%.1f", dpsMean)) px  stddev \(String(format: "%.2f", dpsStd)) px  (lower stddev = smoother)"
        )
        print("zero-motion frames: \(zeroFrames)  |  max single-frame jump: \(maxJump) px")
        print(
            "measured velocity: \(Int(measuredVel)) px/s (commanded \(Int(velocityPhys)) physical px/s)"
        )
        if measuredVel < 0.2 * velocityPhys {
            print("WARNING: measured velocity far below commanded — did the scroll events reach the window?")
        }
        if clipped > 0 {
            print("WARNING: \(clipped) measurements hit the shift search limit (\(maxShift) px) — jumps may be underestimated")
        }
        if cfg.flick, let fm = flickMarkers.value {
            let mEnd = tInjStart + fm.momentumEndS
            print(
                "flick: gesture ended at +\(String(format: "%.2f", fm.gestureEndS))s, momentum ended at +\(String(format: "%.2f", fm.momentumEndS))s"
            )
            let tail = pairs.filter { $0.t >= mEnd - 1.0 }
            print("tail per-frame displacements (last 1.0s of momentum; '*' = after momentum end):")
            print(
                tail.map { p in "\(p.disp)\(p.t >= mEnd ? "*" : "")" }
                    .joined(separator: " "))
        }
        print("artifacts: \(outDir)")
    }
}
