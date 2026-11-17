import Foundation
import notify

public enum ThumbGesture: String, Codable, CaseIterable, CodingKeyRepresentable {
    case click, swipeUp, swipeDown, swipeLeft, swipeRight

    /// Hold-and-move distance (raw sensor counts) → gesture.
    public static func classify(dx: Int, dy: Int, threshold: Int) -> ThumbGesture {
        if max(abs(dx), abs(dy)) < threshold { return .click }
        if abs(dx) > abs(dy) { return dx < 0 ? .swipeLeft : .swipeRight }
        return dy < 0 ? .swipeUp : .swipeDown
    }
}

public struct KeyCombo: Codable, Hashable {
    /// macOS virtual key code; `nil` until one is recorded.
    public var key: UInt16?
    /// `CGEventFlags` / `NSEvent.ModifierFlags` raw value (same bits).
    public var modifiers: UInt64
    /// What to show in the UI, e.g. "⌘⇧4".
    public var display: String

    public init(key: UInt16?, modifiers: UInt64, display: String) {
        self.key = key
        self.modifiers = modifiers
        self.display = display
    }

    public static let unset = KeyCombo(key: nil, modifiers: 0, display: "")
}

public enum Action: Codable, Hashable {
    case missionControl
    case appExpose
    case showDesktop
    case desktopLeft
    case desktopRight
    /// A normal middle-click, e.g. when the middle button is the gesture button.
    case middleClick
    case keystroke(KeyCombo)
    case shell(String)
}

/// Mouse buttons that macOS sees natively (buttons 4 and 5) and Logifree can remap.
public enum MouseButton: String, Codable, CaseIterable, CodingKeyRepresentable {
    case back, forward

    /// `CGEvent` `.mouseEventButtonNumber` (0 = left, 1 = right, 2 = middle).
    public var eventButtonNumber: Int64 { self == .back ? 3 : 4 }

    public init?(eventButtonNumber: Int64) {
        switch eventButtonNumber {
        case 3: self = .back
        case 4: self = .forward
        default: return nil
        }
    }
}

/// Settings that replace the global ones while an app is frontmost.
public struct AppProfile: Codable, Equatable, Identifiable {
    public var id: String { bundleID }
    public var bundleID: String
    public var name: String
    /// Overrides per button; buttons left out use the global mapping.
    public var buttons: [MouseButton: Action]
    /// Replaces all gesture mappings when set; nil uses the global ones.
    public var gestures: [ThumbGesture: Action]?

    public init(bundleID: String, name: String, buttons: [MouseButton: Action] = [:],
                gestures: [ThumbGesture: Action]? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.buttons = buttons
        self.gestures = gestures
    }
}

/// How the scroll wheel's ratchet behaves (HID++ SmartShift).
public enum WheelMode: String, Codable, CaseIterable {
    case unchanged, ratchet, freeSpin, smartShift
}

/// Lives in `~/Library/Application Support/logifree/settings.json`. The app writes
/// it and posts `reloadNotification`; the agent re-reads and re-applies.
public struct Settings: Codable, Equatable {
    public var invertWheel = true
    public var invertThumbwheel = true
    public var gestures: [ThumbGesture: Action] = [
        .click: .missionControl,
        .swipeUp: .missionControl,
        .swipeDown: .appExpose,
        .swipeLeft: .desktopLeft,
        .swipeRight: .desktopRight,
    ]
    public var swipeThreshold = 50
    /// Slow wheel clicks scroll at least this many lines; 1 = macOS default.
    /// Faster scrolling, which macOS already accelerates past this, is untouched.
    public var minimumLinesPerClick = 2
    /// System-wide key → key remaps for every keyboard.
    public var keyRemaps: [KeyRemap] = []
    /// What the back and forward buttons do everywhere. Unmapped buttons stay native.
    public var buttons: [MouseButton: Action] = [:]
    /// Per-app overrides, applied while that app is frontmost.
    public var appProfiles: [AppProfile] = []
    /// Scroll wheel ratchet behaviour; `.unchanged` leaves the mouse's own setting.
    public var wheelMode: WheelMode = .unchanged
    /// SmartShift threshold, 1 (shifts to free spin easily) … 100 (barely).
    public var smartShiftSensitivity = 50

    public init() {}

    /// The profile for an app, if there is one.
    public func profile(for bundleID: String?) -> AppProfile? {
        guard let bundleID else { return nil }
        return appProfiles.first { $0.bundleID == bundleID }
    }

    /// Back/forward mapping in effect for an app: its profile first, then the global one.
    public func buttonAction(_ button: MouseButton, in bundleID: String?) -> Action? {
        profile(for: bundleID)?.buttons[button] ?? buttons[button]
    }

    /// Gesture mapping in effect for an app: its profile's gestures, if it has any, else global.
    public func gestures(in bundleID: String?) -> [ThumbGesture: Action] {
        profile(for: bundleID)?.gestures ?? gestures
    }

    /// Whether any back/forward mapping exists, so the button tap is needed.
    public var mapsButtons: Bool {
        !buttons.isEmpty || appProfiles.contains { !$0.buttons.isEmpty }
    }

    // Missing keys fall back to defaults, so adding a setting never breaks an old file.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()
        invertWheel = try container.decodeIfPresent(Bool.self, forKey: .invertWheel) ?? defaults.invertWheel
        invertThumbwheel = try container.decodeIfPresent(Bool.self, forKey: .invertThumbwheel) ?? defaults.invertThumbwheel
        gestures = try container.decodeIfPresent([ThumbGesture: Action].self, forKey: .gestures) ?? defaults.gestures
        swipeThreshold = try container.decodeIfPresent(Int.self, forKey: .swipeThreshold) ?? defaults.swipeThreshold
        minimumLinesPerClick = try container.decodeIfPresent(Int.self, forKey: .minimumLinesPerClick)
            ?? defaults.minimumLinesPerClick
        keyRemaps = try container.decodeIfPresent([KeyRemap].self, forKey: .keyRemaps) ?? defaults.keyRemaps
        buttons = try container.decodeIfPresent([MouseButton: Action].self, forKey: .buttons) ?? defaults.buttons
        appProfiles = try container.decodeIfPresent([AppProfile].self, forKey: .appProfiles) ?? defaults.appProfiles
        wheelMode = try container.decodeIfPresent(WheelMode.self, forKey: .wheelMode) ?? defaults.wheelMode
        smartShiftSensitivity = try container.decodeIfPresent(Int.self, forKey: .smartShiftSensitivity)
            ?? defaults.smartShiftSensitivity
    }

    public static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/logifree")
    public static let url = directory.appendingPathComponent("settings.json")
    public static let reloadNotification = "dev.raimond.logifree.reload"

    public static func load() -> Settings {
        guard let data = try? Data(contentsOf: url) else { return Settings() }
        do {
            return try JSONDecoder().decode(Settings.self, from: data)
        } catch {
            Log.info("settings.json unreadable, using defaults: \(error)")
            return Settings()
        }
    }

    /// Write, then tell the agent.
    public func save() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url, options: .atomic)
        Self.postReload()
    }

    public static func postReload() { notify_post(reloadNotification) }

    /// Calls `handler` on main whenever someone posts `reloadNotification`.
    public static func observeReload(_ handler: @escaping () -> Void) {
        var token: Int32 = 0
        notify_register_dispatch(reloadNotification, &token, .main) { _ in handler() }
    }
}

/// What the agent reports about itself and your devices, for the app to show.
/// Rewritten by the agent whenever something changes. The agent is the only
/// process that talks to devices, so the window needs no Input Monitoring.
public struct AgentStatus: Codable {
    /// A connected device the agent has configured.
    public struct DeviceState: Codable {
        public var name: String
        public var isMouse: Bool
        /// "Bluetooth" or "Bolt receiver".
        public var route: String
        /// What went wrong applying settings, if anything did.
        public var problem: String?
        /// Easy-Switch channels; empty without Easy-Switch.
        public var slots: [HostSlot]
        public var canForget: Bool
        /// The channel it announced switching to; it's about to leave this Mac.
        public var switchedTo: UInt8?

        public init(name: String, isMouse: Bool, route: String, problem: String?,
                    slots: [HostSlot], canForget: Bool, switchedTo: UInt8?) {
            self.name = name
            self.isMouse = isMouse
            self.route = route
            self.problem = problem
            self.slots = slots
            self.canForget = canForget
            self.switchedTo = switchedTo
        }
    }

    /// An `AgentCommand` the agent couldn't carry out.
    public struct Failure: Codable {
        public var command: UUID
        public var message: String

        public init(command: UUID, message: String) {
            self.command = command
            self.message = message
        }
    }

    public var pid: Int32
    public var accessibility: Bool
    public var devices: [DeviceState]
    public var failure: Failure?

    public init(accessibility: Bool, devices: [DeviceState], failure: Failure?) {
        pid = getpid()
        self.accessibility = accessibility
        self.devices = devices
        self.failure = failure
    }

    public static let url = Settings.directory.appendingPathComponent("status.json")

    public static func load() -> AgentStatus? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AgentStatus.self, from: data)
    }

    public func save() {
        try? FileManager.default.createDirectory(at: Settings.directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: Self.url, options: .atomic)
        notify_post(Self.changedNotification)
    }

    public static let changedNotification = "dev.raimond.logifree.status"
    /// Posted by the app to make the agent undo its changes and exit.
    public static let quitNotification = "dev.raimond.logifree.quit"

    public static func postQuit() { notify_post(quitNotification) }

    public static func observeQuit(_ handler: @escaping () -> Void) {
        var token: Int32 = 0
        notify_register_dispatch(quitNotification, &token, .main) { _ in handler() }
    }

    /// Calls `handler` on main whenever the agent rewrites its status.
    public static func observeChanges(_ handler: @escaping () -> Void) {
        var token: Int32 = 0
        notify_register_dispatch(changedNotification, &token, .main) { _ in handler() }
    }
}

/// An Easy-Switch change the app asks the agent to make on a device.
public struct AgentCommand: Codable {
    public enum Action: Codable {
        case switchHost(UInt8)
        case rename(UInt8, String)
        case forget(UInt8)
    }

    public var id = UUID()
    /// `AgentStatus.DeviceState.name`.
    public var device: String
    public var action: Action

    public init(device: String, action: Action) {
        self.device = device
        self.action = action
    }

    public static let url = Settings.directory.appendingPathComponent("command.json")
    public static let notification = "dev.raimond.logifree.command"

    /// Write, then tell the agent. Failures come back in `AgentStatus.failure`.
    public func send() throws {
        try FileManager.default.createDirectory(at: Settings.directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: Self.url, options: .atomic)
        notify_post(Self.notification)
    }

    /// The pending command, removed so it runs once.
    public static func take() -> AgentCommand? {
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AgentCommand.self, from: data)
    }

    /// Calls `handler` on main whenever the app sends a command.
    public static func observe(_ handler: @escaping () -> Void) {
        var token: Int32 = 0
        notify_register_dispatch(notification, &token, .main) { _ in handler() }
    }
}
