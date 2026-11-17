import LogifreeCore
import ServiceManagement
import SwiftUI

struct ContentView: View {
    @State private var model = AppModel()
    @State private var showAdvanced = false

    var body: some View {
        Form {
            agentSection
            devicesSection
            pointerSection
            scrollingSection
            gestureSection
            buttonsSection
            advancedSection
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 880)
        .alert(model.error?.title ?? "", isPresented: isPresent($model.error)) {} message: {
            Text(model.error?.detail ?? "")
        }
    }

    // MARK: Agent

    private var agentSection: some View {
        Section {
            HStack(spacing: 10) {
                Circle()
                    .fill(model.agentRunning ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text(agentHeadline)
                    .layoutPriority(1)
                if model.agentRunning {
                    Button("Quit") { AppModel.quitCompletely() }
                        .controlSize(.small)
                        .help("Stop Logifree, put your devices back to normal, and close this window. It starts again at login.")
                } else if model.agentEnabled {
                    Button("Start") { model.startAgent() }
                        .controlSize(.small)
                }
                Spacer()
                Text("Start at login")
                    .foregroundStyle(.secondary)
                Toggle("Start at login", isOn: Binding(
                    get: { model.agentService == .enabled || model.agentService == .requiresApproval },
                    set: { model.setAgentEnabled($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
            }
            if model.agentService == .requiresApproval {
                notice("Approve Logifree in Login Items to start it.", button: "Open Login Items") {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
            if model.agentRunning, model.agentStatus?.accessibility == false {
                notice("Gesture actions and scroll distance need Accessibility access for Logifree Agent.", button: "Grant Access…") {
                    model.grantAccessibility()
                }
            }
        } footer: {
            if !model.agentRunning {
                Text("Your settings only take effect while Logifree runs in the background.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var agentHeadline: String {
        if model.agentRunning { return "Running in the background" }
        if model.agentService == .requiresApproval { return "Waiting for approval" }
        return "Not running"
    }

    private func notice(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        HStack {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
            Spacer()
            Button(button, action: action)
        }
    }

    // MARK: Devices

    private var devicesSection: some View {
        Section {
            if model.devices.isEmpty {
                Text(model.agentRunning
                     ? "No devices found. Move your mouse or press a key to wake them."
                     : "Your devices show up here while Logifree runs in the background.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.devices) { row in
                DeviceTile(model: model, row: row)
            }
        } header: {
            Text("Devices")
        }
    }

    // MARK: Mouse settings

    private var scrollingSection: some View {
        Section {
            Toggle("Reverse scroll wheel", isOn: $model.settings.invertWheel)
            Toggle("Reverse thumb wheel", isOn: $model.settings.invertThumbwheel)
            Toggle("Smooth scrolling", isOn: $model.settings.smoothScrolling)
            if model.settings.smoothScrolling {
                LabeledContent("Scroll speed") {
                    HStack {
                        Slider(value: $model.settings.scrollSpeed, in: 0.25...3) {} minimumValueLabel: {
                            Text("Slow").font(.caption)
                        } maximumValueLabel: {
                            Text("Fast").font(.caption)
                        }
                        Text(model.settings.scrollSpeed.formatted(.number.precision(.fractionLength(2))) + "×")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                    .frame(width: 300)
                }
            }
            if model.settings.smoothScrolling {
                LabeledContent("Smoothness") {
                    Slider(value: $model.settings.scrollSmoothness, in: 0...1) {} minimumValueLabel: {
                        Text("Snappy").font(.caption)
                    } maximumValueLabel: {
                        Text("Floaty").font(.caption)
                    }
                    .frame(width: 300)
                }
            }
            Picker("Distance per click", selection: $model.settings.minimumLinesPerClick) {
                Text("macOS default").tag(1)
                Text("2 lines").tag(2)
                Text("3 lines").tag(3)
            }
            .pickerStyle(.segmented)
            Picker("Wheel mode", selection: $model.settings.wheelMode) {
                Text("Leave as is").tag(WheelMode.unchanged)
                Text("Ratchet").tag(WheelMode.ratchet)
                Text("Free spin").tag(WheelMode.freeSpin)
                Text("SmartShift").tag(WheelMode.smartShift)
            }
            if model.settings.wheelMode == .smartShift {
                LabeledContent("SmartShift sensitivity") {
                    Slider(
                        value: Binding(
                            get: { Double(model.settings.smartShiftSensitivity) },
                            set: { model.settings.smartShiftSensitivity = Int($0) }
                        ),
                        in: 1...100
                    )
                    .frame(width: 240)
                }
            }
        } header: {
            Text("Scrolling")
        } footer: {
            Text("A slow click scrolls at least this far. Faster scrolling keeps macOS's own acceleration. Your trackpad isn't affected.")
                .foregroundStyle(.secondary)
        }
    }

    private var gestureSection: some View {
        Section {
            GesturePad(gestures: $model.settings.gestures)
            LabeledContent("Swipe distance") {
                Slider(
                    value: Binding(
                        get: { Double(model.settings.swipeThreshold) },
                        set: { model.settings.swipeThreshold = Int($0) }
                    ),
                    in: 20...200
                ) {} minimumValueLabel: {
                    Text("Short").font(.caption)
                } maximumValueLabel: {
                    Text("Long").font(.caption)
                }
                .frame(width: 240)
            }
        } header: {
            Text("Gesture button")
        } footer: {
            Text("Click the thumb button, or hold it and move the mouse in a direction. On mice without one, such as the MX Anywhere, the middle button takes its place.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Pointer

    private var pointerSection: some View {
        let mouse = model.agentStatus?.devices.first { $0.isMouse && $0.dpi != nil }
        let range = Double(mouse?.dpiMin ?? 200)...Double(mouse?.dpiMax ?? 4000)
        return Section {
            Toggle("Set pointer speed", isOn: Binding(
                get: { model.settings.pointerDPI != nil },
                set: { model.settings.pointerDPI = $0 ? (mouse?.dpi ?? 1000) : nil }
            ))
            if let dpi = model.settings.pointerDPI {
                LabeledContent("Sensor DPI") {
                    HStack {
                        Slider(
                            value: Binding(get: { Double(dpi) },
                                           set: { model.settings.pointerDPI = Int(($0 / 50).rounded()) * 50 }),
                            in: range
                        ) {} minimumValueLabel: {
                            Text("Slow").font(.caption)
                        } maximumValueLabel: {
                            Text("Fast").font(.caption)
                        }
                        Text("\(dpi)").monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                    }
                    .frame(width: 300)
                }
            }
        } header: {
            Text("Pointer")
        } footer: {
            Text(mouse.map { "\($0.name) is at \($0.dpi ?? 0) DPI. macOS's Tracking speed still applies on top." }
                 ?? "Sets the mouse's own sensor speed. macOS's Tracking speed still applies on top.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Back and forward

    private var buttonsSection: some View {
        Section {
            buttonRow("Everywhere", $model.settings.buttons)
            ForEach($model.settings.appProfiles) { $profile in
                HStack(alignment: .top) {
                    buttonRow(profile.name, $profile.buttons)
                    Button { model.settings.appProfiles.removeAll { $0.bundleID == profile.bundleID } } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove \(profile.name)'s settings")
                }
            }
            HStack {
                Spacer()
                Button("Add app…") { model.addAppProfile() }
            }
        } header: {
            Text("Back and forward buttons")
        } footer: {
            Text("Per-app settings apply while that app is in front. \"Native\" keeps the button's own behaviour.")
                .foregroundStyle(.secondary)
        }
    }

    private func buttonRow(_ label: String, _ buttons: Binding<[MouseButton: Action]>) -> some View {
        LabeledContent(label) {
            HStack(alignment: .top) {
                ForEach(MouseButton.allCases, id: \.self) { button in
                    VStack(spacing: 4) {
                        Text(button == .back ? "Back" : "Forward").font(.caption).foregroundStyle(.secondary)
                        ActionPicker(
                            title: button.rawValue,
                            action: Binding(get: { buttons.wrappedValue[button] },
                                            set: { buttons.wrappedValue[button] = $0 }),
                            noneTitle: "Native",
                            width: 130
                        )
                    }
                }
            }
        }
    }

    // MARK: Advanced

    private var advancedSection: some View {
        Section(isExpanded: $showAdvanced) {
            ForEach(model.settings.keyRemaps.indices, id: \.self) { i in
                HStack {
                    keyPicker("From", $model.settings.keyRemaps[i].from)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    keyPicker("To", $model.settings.keyRemaps[i].to)
                    Spacer()
                    Button { model.settings.keyRemaps.remove(at: i) } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this remap")
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Remaps keys on every keyboard, including the built-in one. F13–F20 make good global shortcuts, since no key sends them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Add key remap") {
                    model.settings.keyRemaps.append(KeyRemap(from: 0x64, to: 0x6D)) // § → F18
                }
            }
        } header: {
            Text("Advanced")
        }
    }

    private func keyPicker(_ label: String, _ usage: Binding<UInt16>) -> some View {
        Picker(label, selection: usage) {
            ForEach(KeyCatalog.groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.keys, id: \.usage) { Text($0.name).tag($0.usage) }
                }
            }
        }
        .labelsHidden()
        .fixedSize()
    }
}

func isPresent<T>(_ binding: Binding<T?>) -> Binding<Bool> {
    Binding(get: { binding.wrappedValue != nil }, set: { if !$0 { binding.wrappedValue = nil } })
}
