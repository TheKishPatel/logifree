import AppKit
import CoreGraphics
import Foundation
import LogifreeCore

/// Tracks the frontmost app's bundle ID, readable from any thread.
final class FrontmostApp {
    private let lock = NSLock()
    private var current: String?

    init() {
        current = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.set(app?.bundleIdentifier)
        }
    }

    var bundleID: String? {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    private func set(_ bundleID: String?) {
        lock.lock(); current = bundleID; lock.unlock()
        Log.debug("frontmost: \(bundleID ?? "none")")
    }
}

/// Remaps the back and forward buttons (macOS buttons 4 and 5), globally or per
/// frontmost app, after swapping them if asked. "Middle click" swallows the button and posts a real middle
/// button down/up at the HID level, so the system's pressed-button state says
/// "middle" too and hold-and-drag works (e.g. panning in Figma); drags in between
/// are relabelled as middle drags. Other actions swallow the button and run on
/// press. Unmapped buttons pass through, relabelled if swapped, and with nothing
/// mapped or swapped there's no tap.
///
/// Like `ScrollTap`, the tap runs on its own thread so it never waits on device I/O,
/// and actions run on their own queue rather than behind it on main.
final class ButtonTap {
    /// Tags the events we post.
    private static let marker: Int64 = 0x4C_4F_47_42 // "LOGB"
    private static let actions = DispatchQueue(label: "button actions", qos: .userInteractive)

    private var tap: CFMachPort?
    private let frontmost: FrontmostApp
    private let source = CGEventSource(stateID: .hidSystemState)
    private let lock = NSLock()
    private var _settings = Settings()
    /// What each physical button became when it went down (after any swap) and the
    /// action chosen for it, kept until it comes up so an app switch or settings
    /// change mid-press can't leave a button stuck or split across two buttons.
    private var held: [MouseButton: (button: MouseButton, action: Action?)] = [:]

    init(frontmost: FrontmostApp) {
        self.frontmost = frontmost
    }

    var settings: Settings {
        get { lock.lock(); defer { lock.unlock() }; return _settings }
        set {
            lock.lock(); _settings = newValue; lock.unlock()
            update()
        }
    }

    private func update() {
        let wanted = settings.needsButtonTap
        if wanted, tap == nil { create() }
        if let tap { CGEvent.tapEnable(tap: tap, enable: wanted) }
        // With the tap off, a held button's release would arrive unmapped: let go now.
        if !wanted { releaseHeld() }
    }

    private func releaseHeld() {
        lock.lock()
        let middles = held.filter { $0.value.action == .middleClick }.count
        held = [:]
        lock.unlock()
        guard middles > 0, let location = CGEvent(source: nil)?.location else { return }
        postMiddle(.otherMouseUp, at: location, flags: [], clickState: 1)
    }

    private func create() {
        let mask = [CGEventType.otherMouseDown, .otherMouseUp, .otherMouseDragged]
            .reduce(CGEventMask(0)) { $0 | 1 << $1.rawValue }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                Unmanaged<ButtonTap>.fromOpaque(context!).takeUnretainedValue().handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return Log.info("couldn't watch mouse buttons: Accessibility permission missing")
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFRunLoopRun()
        }
        thread.name = "button tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.tap = tap
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: settings.needsButtonTap) }
            return pass
        }
        guard event.getIntegerValueField(.eventSourceUserData) != Self.marker,
              let physical = MouseButton(eventButtonNumber: event.getIntegerValueField(.mouseEventButtonNumber))
        else { return pass }

        lock.lock()
        let press: (button: MouseButton, action: Action?)
        if type == .otherMouseDown {
            let button = _settings.logicalButton(physical)
            press = (button, _settings.buttonAction(button, in: frontmost.bundleID))
        } else {
            // Pressed before the tap was on: no action ran on press, so none on release.
            press = held[physical] ?? (_settings.logicalButton(physical), nil)
        }
        switch type {
        case .otherMouseDown: held[physical] = press
        case .otherMouseUp: held[physical] = nil
        default: break
        }
        lock.unlock()
        let button = press.button
        guard let action = press.action else {
            if button != physical { event.setIntegerValueField(.mouseEventButtonNumber, value: button.eventButtonNumber) }
            return pass
        }

        guard action == .middleClick else {
            if type == .otherMouseDown {
                Log.debug("\(button) → \(action)")
                Self.actions.async { action.perform() }
            }
            return nil // swallowed: the action runs on press
        }
        switch type {
        case .otherMouseDown, .otherMouseUp:
            postMiddle(type, at: event.location, flags: event.flags,
                       clickState: event.getIntegerValueField(.mouseEventClickState))
            return nil
        default: // drag while held: relabel it as a middle drag
            event.setIntegerValueField(.mouseEventButtonNumber, value: 2)
            return pass
        }
    }

    /// A middle button event posted at the HID level, so the system tracks it as pressed.
    private func postMiddle(_ type: CGEventType, at location: CGPoint, flags: CGEventFlags, clickState: Int64) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: location, mouseButton: .center) else { return }
        event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        event.setIntegerValueField(.mouseEventClickState, value: max(1, clickState))
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
}
