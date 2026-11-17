import CoreGraphics
import Foundation
import LogifreeCore

/// Edits vertical wheel scrolling from mice. Trackpads, Magic Mouse and
/// horizontal scrolling always pass untouched, and with nothing to do there's no tap.
///
/// - Distance per click: slow wheel clicks scroll at least `minimumLines`. Faster
///   scrolling, already accelerated past the minimum by macOS, passes untouched.
/// - Smooth scrolling: each wheel click (with macOS's own acceleration) becomes a
///   short ease-out animation of pixel scrolls, `speed` times the distance apps
///   would scroll for it natively. With ⌘, ⌥ or ⌃ held, clicks pass untouched so
///   zooming and other modified scrolls keep their usual steps.
///
/// The tap runs on its own thread: every scroll on the system waits for it, so
/// it must never sit behind the agent's (blocking) device I/O on main. The
/// animation runs on that same thread.
final class ScrollTap {
    private struct Config {
        var minimumLines = 1
        var smooth = false
        var speed = 1.0
        /// Fraction of the remaining distance scrolled per 120 Hz frame.
        var easing = 0.3
        var active: Bool { minimumLines > 1 || smooth }
    }

    /// Tags the events we post so the tap lets them through.
    private static let marker: Int64 = 0x4C_4F_47_49 // "LOGI"
    /// What browsers and most apps scroll per wheel line.
    private static let pixelsPerLine = 40.0

    private var tap: CFMachPort?
    private let lock = NSLock()
    private var _config = Config()
    private var config: Config {
        lock.lock(); defer { lock.unlock() }
        return _config
    }

    // Animation state: only touched on the tap thread.
    private var remaining = 0.0
    private var carry = 0.0
    private var flags: CGEventFlags = []
    private var timer: CFRunLoopTimer?
    private let source = CGEventSource(stateID: .hidSystemState)

    func apply(_ settings: Settings) {
        lock.lock()
        _config = Config(minimumLines: settings.minimumLinesPerClick, smooth: settings.smoothScrolling,
                         speed: max(0.1, settings.scrollSpeed),
                         // smoothness 0 → 0.5 (settles in ~40 ms), 1 → 0.08 (~300 ms)
                         easing: 0.5 - 0.42 * min(max(settings.scrollSmoothness, 0), 1))
        let active = _config.active
        lock.unlock()
        if active, tap == nil { create() }
        if let tap { CGEvent.tapEnable(tap: tap, enable: active) }
    }

    private func create() {
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.scrollWheel.rawValue),
            callback: { _, type, event, context in
                Unmanaged<ScrollTap>.fromOpaque(context!).takeUnretainedValue().handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return Log.info("couldn't watch the scroll wheel: Accessibility permission missing")
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFRunLoopRun()
        }
        thread.name = "scroll tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.tap = tap
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        let config = config
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: config.active) }
            return pass
        }
        guard type == .scrollWheel,
              event.getIntegerValueField(.eventSourceUserData) != Self.marker,
              // Trackpads and Magic Mouse send continuous (pixel) scrolls; wheels send discrete clicks.
              event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0,
              event.getIntegerValueField(.scrollWheelEventDeltaAxis2) == 0
        else { return pass }

        let lines = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        var fixed = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let point = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        Log.debug("scroll in: lines \(lines) fixed \(fixed) point \(point)")
        guard fixed != 0 else { return pass }
        let sign: Double = fixed < 0 ? -1 : 1
        fixed = sign * max(abs(fixed), Double(config.minimumLines))

        let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]
        if config.smooth, event.flags.intersection(modifiers).isEmpty {
            animate(by: fixed * Self.pixelsPerLine * config.speed, flags: event.flags)
            return nil
        }

        guard config.minimumLines > 1, abs(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)) < fixed.magnitude
        else { return pass }
        let scale = fixed.magnitude / abs(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
        // Writing the line field makes CoreGraphics recompute the other two, so it goes first.
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(fixed))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: fixed)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: point * scale)
        Log.debug("scroll out: lines \(Int(fixed)) fixed \(fixed) point \(point * scale)")
        return pass
    }

    // MARK: Smooth scrolling

    private func animate(by pixels: Double, flags: CGEventFlags) {
        // Reversing direction stops the old scroll at once instead of fighting it.
        if remaining != 0, (remaining < 0) != (pixels < 0) {
            remaining = 0
            carry = 0
        }
        remaining += pixels
        self.flags = flags
        guard timer == nil else { return }
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent(), 1.0 / 120, 0, 0) {
            [unowned self] _ in step()
        }
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
        self.timer = timer
    }

    private func step() {
        var delta = remaining * config.easing
        if abs(remaining) < 2 { delta = remaining }
        remaining -= delta
        carry += delta
        let whole = carry.rounded(.towardZero)
        carry -= whole
        if whole != 0 { post(Int32(whole)) }
        if remaining == 0 {
            carry = 0
            if let timer { CFRunLoopTimerInvalidate(timer) }
            timer = nil
        }
    }

    private func post(_ pixels: Int32) {
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                                  wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0) else { return }
        event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        event.flags = flags
        event.post(tap: .cgSessionEventTap)
    }
}
