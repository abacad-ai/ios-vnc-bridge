import AppKit
import Foundation
import ServiceManagement
import SwiftUI

/// Everything the panel shows and every action it can take.
///
/// One object on purpose: the runtime, the device list and the engine process
/// are one story, and splitting them into nested observable objects only makes
/// the panel miss updates.
@MainActor
final class AppState: ObservableObject {
    /// Set by the one instance the app creates, so the app delegate can stop
    /// the engine when the app quits.
    @MainActor static weak var current: AppState?

    // MARK: Settings

    @Published var port: Int {
        didSet { defaults.set(port, forKey: "port") }
    }
    @Published var bindAll: Bool {
        didSet { defaults.set(bindAll, forKey: "bindAll") }
    }
    @Published var connection: String {
        didSet { defaults.set(connection, forKey: "connection") }
    }
    @Published var deviceUDID: String {
        didSet { defaults.set(deviceUDID, forKey: "deviceUDID") }
    }
    @Published var password: String
    @Published var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin() }
    }
    @Published var autoStart: Bool {
        didSet { defaults.set(autoStart, forKey: "autoStart") }
    }

    // MARK: Runtime

    enum RuntimeStatus: Equatable {
        case unknown
        case checking
        case needsSetup
        case installing
        case ready(String)
        case failed(String)

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }

        var isBusy: Bool {
            switch self {
            case .checking, .installing: return true
            default: return false
            }
        }
    }

    @Published var runtime: RuntimeStatus = .unknown
    @Published var setupLog: [String] = []

    // MARK: Devices

    @Published var devices: [Device] = []
    @Published var refreshingDevices = false

    // MARK: Toolchain

    enum ToolchainStatus: Equatable {
        case unknown
        case ok(String)
        case missing(String)
    }

    @Published var toolchain: ToolchainStatus = .unknown

    // MARK: Engine

    enum EngineStatus: Equatable {
        case stopped
        case starting
        case running
        case failed(String)

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    @Published var status: EngineStatus = .stopped
    @Published var engineLog: [String] = []
    @Published var viewers = 0
    @Published var sessionUp = true
    @Published var listeningPort: Int?

    // MARK: Internals

    let defaults = UserDefaults.standard
    var process: Process?
    var lifeline: Pipe?
    var logStreamer: LineStreamer?
    var lastEngineLine = ""
    var stopping = false

    private let appSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ios-vnc-bridge", isDirectory: true)
    }()

    let logFile: URL = {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/ios-vnc-bridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("ios-vnc-bridge.log")
    }()

    var venvPath: String { appSupport.appendingPathComponent("venv", isDirectory: true).path }
    var venvPython: String { appSupport.appendingPathComponent("venv/bin/python").path }

    init() {
        defaults.register(defaults: [
            "port": 5970, "bindAll": true, "connection": "usb", "deviceUDID": "", "autoStart": true,
        ])
        port = defaults.integer(forKey: "port")
        bindAll = defaults.bool(forKey: "bindAll")
        connection = defaults.string(forKey: "connection") ?? "usb"
        deviceUDID = defaults.string(forKey: "deviceUDID") ?? ""
        launchAtLogin = SMAppService.mainApp.status == .enabled
        autoStart = defaults.bool(forKey: "autoStart")
        if let stored = Credentials.read(), !stored.isEmpty {
            password = stored
        } else {
            let generated = AppState.makePassword()
            password = generated
            Credentials.save(generated)
        }
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        if let size = try? FileManager.default.attributesOfItem(atPath: logFile.path)[.size] as? Int,
           size > 2_000_000 {
            try? FileManager.default.removeItem(at: logFile)
        }
        AppState.current = self

        Task {
            writeLog("app: launched", stamped: false)
            await checkToolchain()
            await checkRuntime()
            writeLog("app: runtime ready=\(runtime.isReady)", stamped: false)
            if runtime.isReady {
                await refreshDevices()
                writeLog("app: \(devices.count) device(s) visible", stamped: false)
                if autoStart && canStart {
                    await start()
                } else {
                    writeLog("app: not auto-starting (autoStart=\(autoStart), canStart=\(canStart))", stamped: false)
                }
            }
        }
    }

    // MARK: Settings helpers

    var viewerAddress: String {
        let host: String
        if bindAll {
            host = primaryIPv4() ?? "127.0.0.1"
        } else {
            host = "127.0.0.1"
        }
        return "\(host):\(listeningPort ?? port)"
    }

    var canStart: Bool {
        runtime.isReady && (1024...65535).contains(port) && !password.isEmpty && process == nil
    }

    func makePassword() {
        password = AppState.makePassword()
        Credentials.save(password)
    }

    func savePassword(_ value: String) {
        Credentials.save(value)
    }

    static func makePassword() -> String {
        let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<8).map { _ in alphabet.randomElement()! })
    }

    func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            appendSetup("launch at login: \(error.localizedDescription)")
            launchAtLogin = SMAppService.mainApp.status == .enabled
        autoStart = defaults.bool(forKey: "autoStart")
        }
    }

    func mergedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = [env["PATH"], extra].compactMap { $0 }.joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }

    // MARK: Log plumbing

    func appendSetup(_ line: String) {
        setupLog.append(line)
        if setupLog.count > 400 { setupLog.removeFirst(setupLog.count - 400) }
        writeLog("setup: \(line)", stamped: false)
    }

    func appendEngine(_ line: String) {
        engineLog.append(line)
        if engineLog.count > 400 { engineLog.removeFirst(engineLog.count - 400) }
        lastEngineLine = line
        writeLog(line, stamped: true)
    }

    /// The log file is what to ask for when something breaks after the panel
    /// has been closed and the scrollback is gone.
    func writeLog(_ line: String, stamped: Bool) {
        let prefix = stamped ? "" : Self.logStamp.string(from: Date()) + " "
        let entry = "\(prefix)\(line)\n"
        guard let data = entry.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logFile) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logFile)
        }
    }

    static let logStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    func clearLog() {
        engineLog.removeAll()
    }
}
