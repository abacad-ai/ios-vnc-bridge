import Foundation

/// Find a Python, create a venv, install the device bridge's one dependency.
///
/// The app does not ship Python: pymobiledevice3 is GPL-3.0-or-later, and this
/// project is MIT. Installing it on the user's machine keeps the distributed
/// bundle free of GPL code (see NOTICE).
extension AppState {
    private struct Interpreter {
        let path: String
        let version: String
    }

    func checkRuntime() async {
        runtime = .checking
        setupLog.removeAll()
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: venvPython) else {
            runtime = .needsSetup
            return
        }
        do {
            let result = try await runCommand(
                venvPython,
                ["-c", "import importlib.metadata; print(importlib.metadata.version('pymobiledevice3'))"],
                environment: mergedEnvironment(),
                timeout: 30
            )
            if result.ok {
                runtime = .ready(result.out.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                runtime = .needsSetup
            }
        } catch {
            runtime = .needsSetup
        }
    }

    func installRuntime() async {
        if runtime.isBusy { return }
        runtime = .installing
        setupLog.removeAll()

        do {
            guard let interpreter = await findInterpreter() else {
                throw RuntimeError.noPython
            }
            appendSetup("Using Python \(interpreter.version) at \(interpreter.path)")

            let fm = FileManager.default
            if fm.fileExists(atPath: venvPath) && !fm.isExecutableFile(atPath: venvPython) {
                appendSetup("Removing an incomplete environment at \(venvPath)")
                try? fm.removeItem(atPath: venvPath)
            }
            if !fm.isExecutableFile(atPath: venvPython) {
                appendSetup("Creating the Python environment…")
                let created = try await runCommand(
                    interpreter.path,
                    ["-m", "venv", venvPath],
                    environment: mergedEnvironment(),
                    timeout: 120
                )
                guard created.ok else {
                    throw RuntimeError.venvFailed(created.err.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }

            appendSetup("Installing pymobiledevice3 — this needs the network once…")
            let status = try await runStreaming(
                venvPython,
                ["-m", "pip", "install", "--disable-pip-version-check", "--upgrade", "pymobiledevice3"]
            )
            guard status == 0 else { throw RuntimeError.pipFailed }

            let verify = try await runCommand(
                venvPython,
                ["-c", "import importlib.metadata; print(importlib.metadata.version('pymobiledevice3'))"],
                environment: mergedEnvironment(),
                timeout: 30
            )
            guard verify.ok else { throw RuntimeError.verifyFailed }
            let version = verify.out.trimmingCharacters(in: .whitespacesAndNewlines)
            appendSetup("pymobiledevice3 \(version) is ready")
            runtime = .ready(version)
            await refreshDevices()
        } catch {
            let message = error.localizedDescription
            appendSetup("Failed: \(message)")
            runtime = .failed(message)
        }
    }

    enum RuntimeError: LocalizedError {
        case noPython
        case venvFailed(String)
        case pipFailed
        case verifyFailed

        var errorDescription: String? {
            switch self {
            case .noPython:
                return "No Python 3.9+ found. Install Xcode 27 (it brings the developer toolchain) or Homebrew python3, then try again."
            case let .venvFailed(message):
                return "Could not create the Python environment: \(message)"
            case .pipFailed:
                return "pip could not install pymobiledevice3 — see the log above."
            case .verifyFailed:
                return "pymobiledevice3 installed but does not import."
            }
        }
    }

    private func findInterpreter() async -> Interpreter? {
        var candidates: [String] = []
        if let explicit = ProcessInfo.processInfo.environment["IOSVNC_PYTHON"], !explicit.isEmpty {
            candidates.append(explicit)
        }
        candidates += ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]

        var seen = Set<String>()
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) && !seen.contains(path) {
            seen.insert(path)
            guard let result = try? await runCommand(
                path,
                ["-c", "import sys; print('%d.%d.%d' % sys.version_info[:3])"],
                environment: mergedEnvironment(),
                timeout: 20
            ), result.ok else { continue }
            let version = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = version.split(separator: ".").compactMap { Int($0) }
            guard parts.count >= 2, (parts[0], parts[1]) >= (3, 9) else {
                appendSetup("Skipping \(path): Python \(version) is too old")
                continue
            }
            return Interpreter(path: path, version: version)
        }
        return nil
    }

    /// Run a long command and stream its output into the setup log.
    private func runStreaming(_ path: String, _ arguments: [String]) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = mergedEnvironment()
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let outLines = LineStreamer(handle: out.fileHandleForReading) { [weak self] line in
            Task { @MainActor in self?.appendSetup(line) }
        }
        let errLines = LineStreamer(handle: err.fileHandleForReading) { [weak self] line in
            Task { @MainActor in self?.appendSetup(line) }
        }

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
                outLines.start()
                errLines.start()
            } catch {
                continuation.resume(throwing: CommandError.launch(path, error))
            }
        }
        outLines.stop()
        errLines.stop()
        return status
    }
}
