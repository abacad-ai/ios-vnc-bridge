import Darwin
import Foundation

/// Starting, stopping and reading the engine's log.
///
/// The engine's log is also the interface: the panel does not need a private
/// protocol, because "listening on", "viewer … connected" and "device session
/// …" already say what happened. Those strings are the contract (see
/// cmd/engine/main.go and internal/helper).
extension AppState {
    func start() async {
        guard canStart else { return }
        guard let engine = BundlePaths.engine, let bridge = BundlePaths.bridge else {
            status = .failed("The app bundle is missing its engine or device bridge.")
            return
        }

        if await portInUse(port) {
            appendEngine("engine: port \(port) is already in use")
            status = .failed("Port \(port) is already in use. Quit whatever is serving there — an older iOS bridge, perhaps — and try again.")
            return
        }

        engineLog.removeAll()
        viewers = 0
        sessionUp = true
        listeningPort = nil
        lastEngineLine = ""
        stopping = false
        status = .starting

        let child = Process()
        child.executableURL = URL(fileURLWithPath: engine.path)
        var arguments = [
            "-listen", "\(bindAll ? "0.0.0.0" : "127.0.0.1"):\(port)",
            "-helper", bridge.path,
            "-helper-python", venvPython,
            "-connection", connection,
            "-name", "iOS VNC Bridge",
        ]
        if !deviceUDID.isEmpty {
            arguments += ["-udid", deviceUDID]
        }
        child.arguments = arguments
        child.environment = mergedEnvironment()

        let stderr = Pipe()
        child.standardError = stderr
        let lifeline = Pipe()
        child.standardInput = lifeline
        child.standardOutput = FileHandle.nullDevice

        let streamer = LineStreamer(handle: stderr.fileHandleForReading) { [weak self] line in
            Task { @MainActor in self?.ingest(line) }
        }
        child.terminationHandler = { [weak self] finished in
            let code = finished.terminationStatus
            Task { @MainActor in self?.engineExited(code: code) }
        }

        do {
            try child.run()
        } catch {
            status = .failed("Could not launch the engine: \(error.localizedDescription)")
            return
        }
        if !password.isEmpty, let handle = try? lifeline.fileHandleForWriting {
            // The password travels over the lifeline, not in argv: `ps` is
            // world-readable, and the engine needs exactly this one secret.
            handle.write(Data((password + "\n").utf8))
        }
        process = child
        self.lifeline = lifeline
        logStreamer = streamer
        streamer.start()
        appendEngine("engine: starting (device \(deviceUDID.isEmpty ? "first paired" : deviceUDID), \(connection))")
    }

    /// Binding 0.0.0.0 succeeds even when another process holds the LAN
    /// address, and then that more specific socket wins every connection: the
    /// app would look live while a stale bridge served the hub. Refuse instead.
    private func portInUse(_ port: Int) async -> Bool {
        var hosts = ["127.0.0.1"]
        if bindAll, let lan = primaryIPv4() { hosts.append(lan) }
        for host in hosts {
            guard let result = try? await runCommand(
                "/usr/bin/nc", ["-z", "-G", "1", host, "\(port)"], timeout: 5
            ) else { continue }
            if result.status == 0 { return true }
        }
        return false
    }

    func stop() {
        guard let child = process else {
            status = .stopped
            return
        }
        stopping = true
        child.terminate()
        let pid = child.processIdentifier
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if let current = self.process, current.processIdentifier == pid, current.isRunning {
                kill(pid, SIGKILL)
            }
        }
    }

    func ingest(_ line: String) {
        appendEngine(line)

        if let range = line.range(of: "listening on ") {
            let rest = line[range.upperBound...]
            if let address = rest.split(separator: " ").first,
               let portPart = address.split(separator: ":").last,
               let number = Int(portPart) {
                listeningPort = number
            }
            status = .running
            sessionUp = true
        }
        if line.contains("viewer ") && line.contains(" connected") {
            viewers += 1
        }
        if line.contains("viewer ") && line.contains(" disconnected") {
            viewers = max(0, viewers - 1)
        }
        if line.contains("device session ended") {
            sessionUp = false
            viewers = 0
        }
        if line.contains("device session restored") {
            sessionUp = true
        }
    }

    func engineExited(code: Int32) {
        process = nil
        lifeline = nil
        logStreamer?.stop()
        logStreamer = nil
        viewers = 0
        listeningPort = nil
        if stopping {
            stopping = false
            status = .stopped
            appendEngine("engine: stopped")
            return
        }
        if code == 0 {
            status = .stopped
            return
        }
        if case .failed = status { return }
        status = .failed(lastEngineLine.isEmpty ? "engine exited with code \(code)" : lastEngineLine)
    }
}
