import AppKit
import SwiftUI

struct PanelView: View {
    @EnvironmentObject private var state: AppState
    @State private var revealPassword = false
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let warning = state.toolchainWarning {
                        warningCard(warning)
                    }
                    runtimeSection
                    if state.runtime.isReady {
                        deviceSection
                        settingsSection
                    }
                    if state.status.isRunning {
                        connectionSection
                    }
                    if case let .failed(message) = state.status {
                        errorCard(message)
                    }
                }
                .padding(16)
            }
            if showLog {
                Divider()
                logSection
            }
            Divider()
            footer
                .padding(12)
        }
        .frame(width: 420, height: 640)
        .task {
            if state.devices.isEmpty, state.runtime.isReady {
                await state.refreshDevices()
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 22, weight: .regular))
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.accentColor.opacity(0.12)))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("iOS VNC Bridge")
                    .font(.headline)
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            statusPill
        }
    }

    private var statusLine: String {
        switch state.status {
        case .stopped:
            return "Not serving"
        case .starting:
            return "Starting the device session…"
        case .running:
            if !state.sessionUp { return "Viewer port is open, device session is down" }
            return state.devices.first(where: { $0.udid == state.deviceUDID })?.name ?? "Serving"
        case let .failed(message):
            return message
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        let (label, color): (String, Color) = {
            switch state.status {
            case .stopped: return ("Stopped", .secondary)
            case .starting: return ("Starting", .orange)
            case .running:
                return state.sessionUp ? ("Live", .green) : ("Waiting", .orange)
            case .failed: return ("Error", .red)
            }
        }()
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.12)))
        .foregroundStyle(color)
    }

    // MARK: Runtime

    @ViewBuilder
    private var runtimeSection: some View {
        switch state.runtime {
        case .ready(let version):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Device runtime ready").font(.callout.weight(.medium))
                    Text("pymobiledevice3 \(version)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Recheck") { Task { await state.checkRuntime() } }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            .card()

        case .unknown, .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking the device runtime…").font(.callout)
                Spacer()
            }
            .card()

        case .needsSetup:
            VStack(alignment: .leading, spacing: 8) {
                Text("Set up the device runtime").font(.callout.weight(.semibold))
                Text("iOS has no VNC server of its own. The app drives the device through Apple's developer services, using pymobiledevice3 — installed locally, once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Install device runtime") {
                    Task { await state.installRuntime() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()

        case .installing:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Installing pymobiledevice3…").font(.callout.weight(.medium))
                }
                Text("This needs the network once. The window can stay closed; the app keeps working.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                setupLogView
            }
            .card()

        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text("Could not set up the runtime").font(.callout.weight(.semibold))
                Text(message).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Try again") { Task { await state.installRuntime() } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("Show details") { showLog = true }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                setupLogView
            }
            .card()
        }
    }

    private var setupLogView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(state.setupLog.suffix(40).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(height: 90)
    }

    // MARK: Device + settings

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Device").font(.callout.weight(.semibold))
                Spacer()
                Button {
                    Task { await state.refreshDevices() }
                } label: {
                    if state.refreshingDevices {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .help("Look for paired devices again")
            }

            if state.devices.isEmpty {
                Text("No paired device found. Connect the iPhone or iPad with a cable, unlock it, and tap Trust.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("", selection: $state.deviceUDID) {
                    ForEach(state.devices) { device in
                        Text("\(device.name) — \(device.subtitle)").tag(device.udid)
                    }
                }
                .labelsHidden()
                .disabled(state.status.isRunning || state.status == .starting)

                Picker("Connection", selection: $state.connection) {
                    Text("USB").tag("usb")
                    Text("Wi-Fi").tag("wifi")
                }
                .pickerStyle(.segmented)
                .disabled(state.status.isRunning || state.status == .starting)
                if state.connection == "wifi" {
                    Text("Wi-Fi needs “Connect to this iPhone over network”, enabled once with the cable in.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .card()
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Viewer access").font(.callout.weight(.semibold))

            HStack {
                Text("Port").frame(width: 60, alignment: .leading)
                TextField("5970", value: $state.port, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .disabled(state.status.isRunning || state.status == .starting)
                Spacer()
                Toggle("Anyone on the LAN", isOn: $state.bindAll)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .disabled(state.status.isRunning || state.status == .starting)
            }

            HStack {
                Text("Password").frame(width: 60, alignment: .leading)
                if revealPassword {
                    TextField("", text: $state.password)
                        .textFieldStyle(.roundedBorder)
                } else {
                    SecureField("", text: $state.password)
                        .textFieldStyle(.roundedBorder)
                }
                Button {
                    revealPassword.toggle()
                } label: {
                    Image(systemName: revealPassword ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(revealPassword ? "Hide the password" : "Show the password")
                Button {
                    state.copy(state.password)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy the password")
                Button {
                    state.makePassword()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderless)
                .help("Generate a new password")
            }
            .onChange(of: state.password) { value in
                state.savePassword(value)
            }

            Text("VNC passwords are limited to 8 characters by the protocol; viewers keep the first 8.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .card()
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(state.bindAll ? "Add this to abacad" : "Local only").font(.callout.weight(.semibold))
                Spacer()
                if state.viewers > 0 {
                    Text(state.viewers == 1 ? "1 viewer" : "\(state.viewers) viewers")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Text(state.viewerAddress)
                    .font(.system(.callout, design: .monospaced))
                Button {
                    state.copy(state.viewerAddress)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy the host and port")
            }
            Text("Platform iOS or iPadOS · Sign-in: VNC password · Mode: Gateway")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if !state.sessionUp {
                Text("The device session ended (cable pulled, device locked, or the tunnel dropped). The app is rebuilding it; viewers are disconnected until a fresh frame arrives.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card()
    }

    // MARK: Cards

    private func warningCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .card()
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("The engine stopped").font(.callout.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // MARK: Log

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Log").font(.caption.weight(.semibold))
                Spacer()
                Text("last \(min(state.engineLog.count, 200)) lines")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("Clear") { state.clearLog() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(state.engineLog.suffix(200).enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                }
                .onChange(of: state.engineLog.count) { _ in
                    withAnimation { proxy.scrollTo(min(state.engineLog.count, 200) - 1) }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(height: 150)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                if state.status.isRunning || state.status == .starting {
                    state.stop()
                } else {
                    Task { await state.start() }
                }
            } label: {
                HStack(spacing: 6) {
                    if state.status == .starting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: state.status.isRunning ? "stop.fill" : "play.fill")
                    }
                    Text(state.status.isRunning ? "Stop" : state.status == .starting ? "Starting…" : "Start")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(state.status == .starting || (!state.status.isRunning && !state.canStart))

            Toggle("Log", isOn: $showLog)
                .toggleStyle(.checkbox)
                .font(.caption)

            Menu {
                Toggle("Launch at login", isOn: $state.launchAtLogin)
                Toggle("Start when a device is found", isOn: $state.autoStart)
                Button("Show log in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([state.logFile])
                }
                Button("Recheck runtime") { Task { await state.checkRuntime() } }
                Button("Refresh devices") { Task { await state.refreshDevices() } }
                Divider()
                Button("Quit iOS VNC Bridge") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}

private extension View {
    func card() -> some View {
        padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06))
            )
    }
}
