import Darwin
import Foundation

/// One paired device as usbmuxd lists it.
struct Device: Identifiable, Hashable {
    let udid: String
    let name: String
    let product: String
    let version: String
    let connection: String

    var id: String { udid }

    var subtitle: String {
        var parts = [product.isEmpty ? "iOS device" : product]
        if !version.isEmpty { parts.append("iOS \(version)") }
        if !connection.isEmpty { parts.append(connection) }
        return parts.joined(separator: " · ")
    }
}

struct CommandResult {
    let status: Int32
    let out: String
    let err: String

    var ok: Bool { status == 0 }
}

enum CommandError: LocalizedError {
    case launch(String, Error)
    case failed(String, Int32, String)

    var errorDescription: String? {
        switch self {
        case let .launch(path, error):
            return "could not launch \(path): \(error.localizedDescription)"
        case let .failed(path, status, output):
            let tail = output.split(separator: "\n").suffix(3).joined(separator: " / ")
            return "\(path) exited \(status)\(tail.isEmpty ? "" : ": \(tail)")"
        }
    }
}

/// Run a short-lived command and collect both pipes without deadlocking.
func runCommand(
    _ path: String,
    _ arguments: [String],
    environment: [String: String]? = nil,
    timeout: TimeInterval = 120
) async throws -> CommandResult {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            if let environment { process.environment = environment }
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: CommandError.launch(path, error))
                return
            }

            // Drain both pipes concurrently: pip and xcodebuild easily fill a
            // 64 KB pipe buffer, and reading one to EOF before the other
            // deadlocks.
            let group = DispatchGroup()
            var output = Data()
            var errorOutput = Data()
            group.enter()
            DispatchQueue.global().async {
                output = out.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                errorOutput = err.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }

            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                usleep(50_000)
            }
            if process.isRunning {
                process.terminate()
                usleep(200_000)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            group.wait()

            continuation.resume(returning: CommandResult(
                status: process.terminationStatus,
                out: String(decoding: output, as: UTF8.self),
                err: String(decoding: errorOutput, as: UTF8.self)
            ))
        }
    }
}

/// Split a stream of bytes into lines, for readabilityHandler callbacks.
final class LineStreamer {
    private var buffer = Data()
    private let handle: FileHandle
    private let onLine: (String) -> Void

    init(handle: FileHandle, onLine: @escaping (String) -> Void) {
        self.handle = handle
        self.onLine = onLine
    }

    func start() {
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.consume(data)
        }
    }

    func stop() {
        handle.readabilityHandler = nil
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            let line = String(decoding: lineData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { onLine(line) }
        }
    }
}

/// The LAN address a viewer on another machine would use.
func primaryIPv4() -> String? {
    var address: String?
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
    defer { freeifaddrs(ifaddr) }
    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let flags = Int32(ptr.pointee.ifa_flags)
        guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
        guard let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let length = socklen_t(addr.pointee.sa_len)
        let result = getnameinfo(addr, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        guard result == 0 else { continue }
        let name = String(cString: host)
        if name.hasPrefix("169.254.") { continue }
        address = name
        break
    }
    return address
}

