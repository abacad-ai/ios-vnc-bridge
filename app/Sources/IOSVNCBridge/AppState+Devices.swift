import Foundation

/// Device discovery and the Xcode prerequisite check.
extension AppState {
    private struct RawDevice: Decodable {
        let Identifier: String?
        let UniqueDeviceID: String?
        let DeviceName: String?
        let ProductType: String?
        let ProductVersion: String?
        let ConnectionType: String?
    }

    func refreshDevices() async {
        guard runtime.isReady else {
            devices = []
            return
        }
        refreshingDevices = true
        defer { refreshingDevices = false }

        do {
            let result = try await runCommand(
                venvPython,
                ["-m", "pymobiledevice3", "usbmux", "list"],
                environment: mergedEnvironment(),
                timeout: 60
            )
            guard result.ok else { return }
            // The command prints a JSON array; be forgiving about any prefix.
            guard let start = result.out.firstIndex(of: "["),
                  let end = result.out.lastIndex(of: "]") else { return }
            let json = String(result.out[start...end])
            let raw = try JSONDecoder().decode([RawDevice].self, from: Data(json.utf8))
            let list = raw.compactMap { entry -> Device? in
                let udid = entry.UniqueDeviceID ?? entry.Identifier ?? ""
                guard !udid.isEmpty else { return nil }
                return Device(
                    udid: udid,
                    name: entry.DeviceName ?? "iOS device",
                    product: entry.ProductType ?? "",
                    version: entry.ProductVersion ?? "",
                    connection: entry.ConnectionType ?? ""
                )
            }
            devices = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            if !devices.contains(where: { $0.udid == deviceUDID }) {
                deviceUDID = devices.first?.udid ?? ""
            }
        } catch {
            appendSetup("device list failed: \(error.localizedDescription)")
        }
    }

    func checkToolchain() async {
        let selection: CommandResult
        do {
            selection = try await runCommand("/usr/bin/xcode-select", ["-p"], timeout: 20)
        } catch {
            toolchain = .missing("Xcode 27 is required — install it from the App Store.")
            return
        }
        guard selection.ok else {
            toolchain = .missing("Xcode 27 is required — install it from the App Store.")
            return
        }
        let developerDir = selection.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard developerDir.contains("Xcode.app") else {
            toolchain = .missing("Only the Command Line Tools are selected. Open Xcode 27 once, or run: sudo xcode-select -s /Applications/Xcode.app")
            return
        }
        do {
            let version = try await runCommand("/usr/bin/xcodebuild", ["-version"], timeout: 15)
            let first = version.out.split(separator: "\n").first.map(String.init) ?? "Xcode"
            toolchain = version.ok ? .ok(first) : .missing(first)
        } catch {
            toolchain = .missing("Xcode 27 is required — install it from the App Store.")
        }
    }

    var toolchainWarning: String? {
        if case let .missing(message) = toolchain { return message }
        return nil
    }
}
