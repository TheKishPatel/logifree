import ApplicationServices
import Foundation
import LogifreeCore

/// Applies `Settings` to every Logitech device as it connects, and turns gesture
/// button events into actions. Idle = parked in the run loop; nothing polls.
final class Daemon {
    /// A connected device plus the agent's bookkeeping for it.
    private final class Tracked {
        let device: Device
        /// The control acting as gesture button: thumb button, or middle button on
        /// mice without one (e.g. MX Anywhere). Nil without either.
        var gestureButton: [UInt8]?
        var gestureHeld = false
        var gestureDX = 0
        var gestureDY = 0
        var configureGeneration = 0
        /// Configured and still on this Mac; only these are reported to the app.
        var configured = false
        var problem: String?
        var slots: [HostSlot] = []
        var canForget = false
        var switchedTo: UInt8?
        var dpi: Int?
        var defaultDPI: Int?
        var dpiList: DPIList?
        init(_ device: Device) { self.device = device }
    }

    private let monitor = HIDMonitor()
    private let scrollTap = ScrollTap()
    private let frontmost = FrontmostApp()
    private lazy var buttonTap = ButtonTap(frontmost: frontmost)
    private var remapsApplied = false
    private var tracked: [Tracked] = []
    private var settings = Settings.load()
    private var failure: AgentStatus.Failure?

    private static let thumbButton: [UInt8] = [0x00, 0xC3]
    private static let middleButton: [UInt8] = [0x00, 0x52]
    /// Back and forward. Left native (Logifree remaps them from their macOS events),
    /// but undiverted on connect in case other software, e.g. Logi Options+, left them diverted.
    private static let nativeButtons: [[UInt8]] = [[0x00, 0x53], [0x00, 0x56]]

    func run() -> Never {
        Log.info("logifree agent started")
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            Log.info("no Accessibility permission yet: gesture actions can't send shortcuts until it's granted")
        }
        scrollTap.apply(settings)
        buttonTap.settings = settings
        applyKeyRemaps()
        Settings.observeReload { [unowned self] in reload() }
        AgentStatus.observeQuit { [unowned self] in quit() }
        AgentCommand.observe { [unowned self] in if let command = AgentCommand.take() { perform(command) } }
        monitor.onAttach = { [unowned self] in attach($0) }
        monitor.onDetach = { [unowned self] transport in
            tracked.removeAll { $0.device.transport === transport }
            Log.info("\(transport.productName) disconnected")
            writeStatus()
        }
        monitor.start()
        writeStatus()
        CFRunLoopRun()
        exit(0)
    }

    /// The app also posts a reload whenever its window becomes active, so only
    /// talk to devices when something they care about changed.
    private func reload() {
        let old = settings
        settings = Settings.load()
        scrollTap.apply(settings) // also retries the tap once Accessibility is granted
        buttonTap.settings = settings
        if settings.keyRemaps != old.keyRemaps { applyKeyRemaps() }
        let ready = tracked.filter(\.configured)
        if settings.pointerDPI != old.pointerDPI {
            ready.forEach { applyDPI($0, restoreDefault: old.pointerDPI != nil) }
        }
        if settings.wheelMode != old.wheelMode || settings.smartShiftSensitivity != old.smartShiftSensitivity {
            ready.forEach { applyWheelMode($0.device, restoreDefault: old.wheelMode != .unchanged) }
        }
        if settings.invertWheel != old.invertWheel || settings.invertThumbwheel != old.invertThumbwheel
            || divertsGesture(settings) != divertsGesture(old) {
            Log.info("settings changed: reconfiguring devices")
            tracked.forEach { scheduleConfigure($0, after: 0) }
        }
        writeStatus()
    }

    /// Whether any gesture does something, so the button needs diverting.
    private func divertsGesture(_ settings: Settings) -> Bool {
        let all = [settings.gestures] + settings.appProfiles.compactMap(\.gestures)
        return all.contains { $0.values.contains { $0 != .keystroke(.unset) && $0 != .shell("") } }
    }

    /// Puts devices back to how they'd be without Logifree, then exits cleanly so
    /// launchd leaves it stopped until the next login (or the app starts it).
    private func quit() {
        Log.info("quitting: restoring devices")
        let ready = tracked.filter(\.configured)
        if settings.pointerDPI != nil {
            settings.pointerDPI = nil
            ready.forEach { applyDPI($0, restoreDefault: true) }
        }
        if settings.wheelMode != .unchanged {
            settings.wheelMode = .unchanged
            ready.forEach { applyWheelMode($0.device, restoreDefault: true) }
        }
        settings.invertWheel = false
        settings.invertThumbwheel = false
        settings.gestures = [:]
        settings.appProfiles = []
        settings.buttons = [:]
        settings.keyRemaps = []
        settings.smoothScrolling = false
        settings.minimumLinesPerClick = 1
        scrollTap.apply(settings)
        buttonTap.settings = settings
        applyKeyRemaps()
        tracked.forEach { _ = configure($0) }
        exit(0)
    }

    private func writeStatus() {
        let devices = tracked.filter(\.configured).map { entry in
            AgentStatus.DeviceState(
                name: entry.device.name,
                isMouse: entry.device.isMouse,
                route: entry.device.transport.kind == .bluetooth ? "Bluetooth" : "Bolt receiver",
                problem: entry.problem,
                slots: entry.slots,
                canForget: entry.canForget,
                switchedTo: entry.switchedTo,
                dpi: entry.dpi,
                dpiMin: entry.dpiList?.minimum,
                dpiMax: entry.dpiList?.maximum
            )
        }
        AgentStatus(accessibility: AXIsProcessTrusted(), devices: devices, failure: failure).save()
    }

    /// Leaves the system's remaps alone unless we have some (or had, and need to clear them).
    private func applyKeyRemaps() {
        guard !settings.keyRemaps.isEmpty || remapsApplied else { return }
        let ok = KeyRemap.apply(settings.keyRemaps)
        remapsApplied = !settings.keyRemaps.isEmpty
        let summary = settings.keyRemaps.map { "\(KeyCatalog.name($0.from)) → \(KeyCatalog.name($0.to))" }
        Log.info(ok ? "key remaps: \(summary.isEmpty ? "cleared" : summary.joined(separator: ", "))" : "couldn't set key remaps")
    }

    private func attach(_ transport: Transport) {
        Log.info("found \(transport.productName) (\(transport.kind))")
        applyKeyRemaps() // a keyboard may have just (re)connected
        transport.onNotification = { [unowned self, unowned transport] in notification(transport, $0) }
        for device in transport.discoverDevices() {
            let entry = Tracked(device)
            tracked.append(entry)
            scheduleConfigure(entry, after: 0)
        }
    }

    private func entry(_ transport: Transport, _ index: UInt8) -> Tracked? {
        tracked.first { $0.device.transport === transport && $0.device.index == index }
    }

    private func notification(_ transport: Transport, _ report: [UInt8]) {
        // Receiver: a device (re)connected, e.g. woke from sleep.
        if report[0] == 0x10 && report[2] == 0x41 && transport.kind == .receiver {
            if report[4] & 0x40 != 0 { // link lost: asleep, or switched to another computer
                if let entry = entry(transport, report[1]), entry.configured {
                    entry.configured = false
                    writeStatus()
                }
                return
            }
            let entry = entry(transport, report[1]) ?? {
                let entry = Tracked(Device(transport: transport, index: report[1]))
                tracked.append(entry)
                return entry
            }()
            scheduleConfigure(entry, after: 0.5)
            return
        }

        // HID++ 2.0 events from a device carry software ID 0.
        guard report[0] == 0x11, report[3] & 0x0F == 0, let entry = entry(transport, report[1]) else { return }
        let function = report[3] >> 4
        let params = Array(report.dropFirst(4))

        if report[2] == entry.device.cachedIndex(HIDPP.Feature.wirelessStatus) {
            // Device reconnected and forgot our settings.
            scheduleConfigure(entry, after: 0.5)
        } else if report[2] == entry.device.cachedIndex(HIDPP.Feature.changeHost), function == 0 {
            // Easy-Switch button pressed: [from, to], sent just before it leaves.
            entry.switchedTo = params[1]
            writeStatus()
        } else if report[2] == entry.device.cachedIndex(HIDPP.Feature.reprogControls) {
            if function == 0 { divertedButtons(entry, params) }
            if function == 1, entry.gestureHeld {
                entry.gestureDX += Int(Int16(bitPattern: UInt16(params[0]) << 8 | UInt16(params[1])))
                entry.gestureDY += Int(Int16(bitPattern: UInt16(params[2]) << 8 | UInt16(params[3])))
            }
        }
    }

    private func divertedButtons(_ entry: Tracked, _ params: [UInt8]) {
        let pressed = stride(from: 0, to: 8, by: 2).contains { Array(params[$0...$0 + 1]) == entry.gestureButton }
        if pressed && !entry.gestureHeld {
            entry.gestureHeld = true
            entry.gestureDX = 0
            entry.gestureDY = 0
        } else if !pressed && entry.gestureHeld {
            entry.gestureHeld = false
            let gesture = ThumbGesture.classify(dx: entry.gestureDX, dy: entry.gestureDY, threshold: settings.swipeThreshold)
            settings.gestures(in: frontmost.bundleID)[gesture]?.perform()
        }
    }

    /// Debounced: reconnects tend to arrive as a burst of notifications.
    private func scheduleConfigure(_ entry: Tracked, after delay: TimeInterval, attempt: Int = 1) {
        entry.configureGeneration += 1
        let generation = entry.configureGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak entry] in
            guard let self, let entry, entry.configureGeneration == generation else { return }
            if configure(entry) {
                writeStatus()
            } else if attempt < 3 {
                scheduleConfigure(entry, after: 1, attempt: attempt + 1)
            }
        }
    }

    /// Returns false if the device didn't answer (asleep, mid-reconnect).
    private func configure(_ entry: Tracked) -> Bool {
        let device = entry.device
        device.resetFeatures()
        entry.gestureHeld = false
        guard device.ping() else { return false }
        device.loadIdentity()
        _ = device.has(HIDPP.Feature.wirelessStatus) // cache its index to spot reconnects

        var applied: [String] = []
        var problems: [String] = []
        func attempt(_ label: String, _ body: () throws -> Void) {
            do { try body(); applied.append(label) } catch HIDPPError.unsupported {
            } catch { problems.append("\(label) failed: \(error)") }
        }

        if device.has(HIDPP.Feature.hiresWheel) {
            attempt(settings.invertWheel ? "wheel inverted" : "wheel normal") {
                let mode = try device.call(HIDPP.Feature.hiresWheel, 1) // getWheelMode
                // Bit 0: report via HID++ (no, keep native). Bit 1: hi-res (no, native
                // macOS doesn't understand it). Bit 2: invert. Keep the other bits.
                let flags = mode[0] & ~0x07 | (settings.invertWheel ? 0x04 : 0)
                try device.call(HIDPP.Feature.hiresWheel, 2, [flags, mode[1], mode[2]])
            }
        }
        if device.has(HIDPP.Feature.thumbwheel) {
            attempt(settings.invertThumbwheel ? "thumb wheel inverted" : "thumb wheel normal") {
                try device.call(HIDPP.Feature.thumbwheel, 2, [0, settings.invertThumbwheel ? 1 : 0])
            }
        }
        if settings.wheelMode != .unchanged {
            attempt("wheel \(settings.wheelMode)") { try setWheelMode(device) }
        }
        if device.isMouse, device.has(HIDPP.Feature.adjustableDPI) {
            if let (current, defaultDPI) = try? device.sensorDPI() {
                entry.dpi = current
                entry.defaultDPI = defaultDPI
                Log.info("\(device.name): sensor at \(current) DPI (default \(defaultDPI))")
            }
            entry.dpiList = try? device.sensorDPIList()
            if let wanted = settings.pointerDPI {
                attempt("pointer \(wanted) DPI") { entry.dpi = try device.setSensorDPI(wanted, list: entry.dpiList) }
            }
        }
        if device.isMouse {
            for button in Self.nativeButtons { // fails harmlessly for controls it doesn't have
                _ = try? device.call(HIDPP.Feature.reprogControls, 3, button + [0x02])
            }
        }
        // getCidReporting fails for a control the mouse doesn't have.
        entry.gestureButton = !device.isMouse ? nil : [Self.thumbButton, Self.middleButton].first { button in
            (try? device.call(HIDPP.Feature.reprogControls, 2, button)) != nil
        }
        if let button = entry.gestureButton {
            let divert = divertsGesture(settings)
            let name = button == Self.thumbButton ? "gesture button" : "middle button"
            attempt(divert ? "\(name) diverted" : "\(name) native") {
                // setCidReporting flags: divert (bit 0, valid bit 1), raw XY (bit 4, valid
                // bit 5) so swipes can be measured. Undiverting = valid bits, values 0.
                do {
                    try device.call(HIDPP.Feature.reprogControls, 3, button + [divert ? 0x33 : 0x22])
                } catch HIDPPError.hidpp20 where divert {
                    try device.call(HIDPP.Feature.reprogControls, 3, button + [0x03])
                    Log.info("\(device.name): no raw XY on the \(name), only clicks will work")
                }
            }
        }
        loadSlots(entry)
        entry.switchedTo = nil
        entry.configured = true
        entry.problem = problems.isEmpty ? nil : problems.joined(separator: "; ")
        let summary = (applied + problems).joined(separator: ", ")
        Log.info("\(device.name) (\(device.kindName), \(device.route)): \(summary.isEmpty ? "nothing to do" : summary)")
        return true
    }

    /// Sets the wanted DPI, or with none, optionally puts back the sensor's default.
    private func applyDPI(_ entry: Tracked, restoreDefault: Bool) {
        let target = settings.pointerDPI ?? (restoreDefault ? entry.defaultDPI : nil)
        guard let target, entry.device.isMouse, entry.dpiList != nil || entry.defaultDPI != nil else { return }
        do {
            entry.dpi = try entry.device.setSensorDPI(target, list: entry.dpiList)
            Log.info("\(entry.device.name): pointer \(entry.dpi ?? target) DPI")
        } catch {
            Log.info("\(entry.device.name): couldn't set \(target) DPI: \(error)")
        }
    }

    /// Sets the wanted wheel mode, or with `.unchanged`, optionally puts back the
    /// factory behaviour: ratchet, shifting to free spin at the default threshold.
    private func applyWheelMode(_ device: Device, restoreDefault: Bool) {
        guard settings.wheelMode != .unchanged || restoreDefault else { return }
        do {
            if settings.wheelMode != .unchanged {
                try setWheelMode(device)
            } else if device.has(HIDPP.Feature.smartShiftEnhanced) {
                let defaultThreshold = try device.call(HIDPP.Feature.smartShiftEnhanced, 0)[1] // getCapabilities
                try device.call(HIDPP.Feature.smartShiftEnhanced, 2, [2, defaultThreshold, 0])
            } else {
                let defaultThreshold = try device.call(HIDPP.Feature.smartShift, 0)[2] // getRatchetControlMode
                try device.call(HIDPP.Feature.smartShift, 1, [2, defaultThreshold, 0])
            }
            Log.info("\(device.name): wheel \(settings.wheelMode == .unchanged ? "restored" : "\(settings.wheelMode)")")
        } catch HIDPPError.unsupported {
        } catch {
            Log.info("\(device.name): couldn't set the wheel mode: \(error)")
        }
    }

    /// SmartShift: [wheel mode (1 free spin, 2 ratchet), auto-disengage threshold
    /// (0 = keep, 0xFF = never), default threshold (0 = keep)].
    private func setWheelMode(_ device: Device) throws {
        let threshold = UInt8(max(1, min(50, (100 - settings.smartShiftSensitivity) / 2)))
        let params: [UInt8] = switch settings.wheelMode {
        case .unchanged: []
        case .freeSpin: [1, 0, 0]
        case .ratchet: [2, 0xFF, 0]
        case .smartShift: [2, threshold, 0]
        }
        guard !params.isEmpty else { return }
        if device.has(HIDPP.Feature.smartShiftEnhanced) {
            try device.call(HIDPP.Feature.smartShiftEnhanced, 2, params)
        } else {
            try device.call(HIDPP.Feature.smartShift, 1, params) // throws .unsupported without it
        }
    }

    // MARK: Easy-Switch

    private func loadSlots(_ entry: Tracked) {
        let device = entry.device
        entry.slots = device.hasEasySwitch ? (try? device.hostSlots()) ?? [] : []
        entry.canForget = !entry.slots.isEmpty && device.canForgetHosts
    }

    /// Runs a change the app asked for, then reports the result.
    private func perform(_ command: AgentCommand) {
        guard let entry = tracked.first(where: { $0.configured && $0.device.name == command.device }) else {
            failure = .init(command: command.id, message: "\(command.device) isn't connected.")
            return writeStatus()
        }
        let device = entry.device
        do {
            switch command.action {
            case .switchHost(let slot):
                entry.switchedTo = slot
                try device.switchHost(to: slot) // it leaves without replying
            case .rename(let slot, let name):
                try device.renameHost(slot, to: name)
                loadSlots(entry)
            case .forget(let slot):
                try device.forgetHost(slot)
                loadSlots(entry)
            }
            failure = nil
        } catch {
            entry.switchedTo = nil
            failure = .init(command: command.id, message: "The device answered: \(error).")
        }
        writeStatus()
    }
}
