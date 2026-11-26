import Foundation

/// The VNC password lives in a 0600 file next to the runtime.
///
/// Not the keychain, deliberately: an ad-hoc signed build has a different code
/// identity after every rebuild, and keychain ACLs then block `SecItemCopyMatching`
/// behind a prompt that a menu-bar app cannot reliably show — the main thread
/// hangs before the UI exists. A user-only file has neither failure mode.
enum Credentials {
    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ios-vnc-bridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("vnc-password")
    }

    static func read() -> String? {
        try? String(contentsOf: fileURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func save(_ value: String) {
        try? Data(value.utf8).write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

/// Where the two non-Swift halves live: inside the app bundle when shipped,
/// or under the checkout during development (`IOSVNC_BRIDGE_ROOT=...`).
enum BundlePaths {
    static var engine: URL? { find("engine") }
    static var bridge: URL? { find("bridge/iosbridge.py") }

    private static func find(_ name: String) -> URL? {
        let fm = FileManager.default
        if let resources = Bundle.main.resourceURL {
            let url = resources.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { return url }
        }
        if let root = ProcessInfo.processInfo.environment["IOSVNC_BRIDGE_ROOT"] {
            for candidate in ["\(root)/build/\(name)", "\(root)/\(name)"] {
                if fm.fileExists(atPath: candidate) { return URL(fileURLWithPath: candidate) }
            }
        }
        return nil
    }
}
