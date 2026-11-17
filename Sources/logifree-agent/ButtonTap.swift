import AppKit
import CoreGraphics
import Foundation
import LogifreeCore

/// Tracks the frontmost app's bundle ID, readable from any thread.
final class FrontmostApp {
    private let lock = NSLock()
    private var current: String?
    /// Called on main after the frontmost app changes.
    var onChange: ((String?) -> Void)?

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
        lock.lock()
        let changed = current != bundleID
        current = bundleID
        lock.unlock()
        if changed {
            Log.debug("frontmost: \(bundleID ?? "none")")
            onChange?(bundleID)
        }
    }
}

/// Remaps the back and forward buttons (macOS buttons 4 and 5), globally or per
/// frontmost app. It edits macOS's own mouse events: "Middle click" rewrites the
/// button number in place, so holding and dragging works (e.g. panning in Figma);
/// other actions swallow the button and run on press. Unmapped buttons pass
/// untouched, and with nothing mapped there's no tap at all.
///
/// Like `ScrollTap`, the tap runs on its own thread so it never waits on device I/O.
final class ButtonTap {
    private var tap: CFMachPort?
    private let frontmost: FrontmostApp
    private let lock = NSLock()
    private var _settings = Settings()
    /// The action chosen when each button went down, kept until it comes up so an
    /// app switch mid-press can't leave a button stuck.
    private var held: [MouseButton: Action] = [:]

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
        let wanted = settings.mapsButtons
        if wanted, tap == nil { create() }
        if let tap { CGEvent.tapEnable(tap: tap, enable: wanted) }
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
            if let tap { CGEvent.tapEnable(tap: tap, enable: settings.mapsButtons) }
            return pass
        }
        guard let button = MouseButton(eventButtonNumber: event.getIntegerValueField(.mouseEventButtonNumber))
        else { return pass }

        let action: Action
        switch type {
        case .otherMouseDown:
            guard let mapped = settings.buttonAction(button, in: frontmost.bundleID) else { return pass }
            held[button] = mapped
            action = mapped
            if mapped != .middleClick {
                Log.debug("\(button) → \(mapped)")
                DispatchQueue.main.async { mapped.perform() }
            }
        case .otherMouseDragged:
            guard let mapped = held[button] else { return pass }
            action = mapped
        case .otherMouseUp:
            guard let mapped = held.removeValue(forKey: button) else { return pass }
            action = mapped
        default:
            return pass
        }

        guard action == .middleClick else { return nil } // swallowed: the action already ran
        event.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        return pass
    }
}
