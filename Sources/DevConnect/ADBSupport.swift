import CoreImage
import CoreImage.CIFilterBuiltins
import Darwin
import Foundation

enum PairMode: String, Equatable {
    case qr
    case code
}

struct ADBDevice: Identifiable, Equatable {
    var id: String { serial }
    let serial: String
    let state: String
    let model: String
    let hardware: String

    var isWireless: Bool { serial.contains(":") }
    var isMDNSHostname: Bool {
        serial.localizedCaseInsensitiveContains(".local:")
    }
    var title: String { model.isEmpty ? serial : model }
    var isReady: Bool { state == "device" }
    var wirelessPort: Int? {
        guard let colon = serial.lastIndex(of: ":") else { return nil }
        return Int(serial[serial.index(after: colon)...])
    }
}

struct PairingTarget: Identifiable, Equatable {
    var id: String { "\(host):\(port)" }
    let name: String
    let host: String
    let port: Int
}

struct NearbyPhone: Identifiable, Equatable {
    var id: String { host }
    let host: String
    let pairing: PairingTarget?
    let connect: PairingTarget?

    var actionTitle: String { pairing != nil ? "Pair" : "Connect" }
}

enum QRCodeImage {
    static func make(_ payload: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}

enum ADBPath {
    static func detect(override: String?) -> String? {
        let trimmed = override?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty, FileManager.default.isExecutableFile(atPath: trimmed) {
            return trimmed
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/Library/Android/sdk/platform-tools/adb.real",
            "\(home)/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "\(home)/bin/adb"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

enum Shell {
    static func run(executable: String, arguments: [String], timeout: TimeInterval) -> (status: Int32, output: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let group = DispatchGroup()
        group.enter()
        proc.terminationHandler = { _ in group.leave() }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            _ = group.wait(timeout: .now() + 1)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (proc.terminationStatus, output)
    }

    static func ipv4(for hostname: String) -> String? {
        let host = hostname.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_INET,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &info) == 0, let first = info else { return nil }
        defer { freeaddrinfo(first) }
        guard first.pointee.ai_family == AF_INET, let sock = first.pointee.ai_addr else { return nil }
        var addr = sock.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buf)
    }
}

enum ADB {
    static func devices(path: String) -> [ADBDevice] {
        let result = Shell.run(executable: path, arguments: ["devices", "-l"], timeout: 8)
        var found: [ADBDevice] = []
        for line in result.output.split(separator: "\n").dropFirst() {
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            guard parts.count >= 2 else { continue }
            let serial = String(parts[0])
            let state = String(parts[1])
            var model = ""
            var hardware = ""
            for part in parts {
                if part.hasPrefix("model:") {
                    model = String(part.dropFirst("model:".count)).replacingOccurrences(of: "_", with: " ")
                }
                if part.hasPrefix("device:") {
                    hardware = String(part.dropFirst("device:".count))
                }
            }
            found.append(ADBDevice(serial: serial, state: state, model: model, hardware: hardware))
        }
        return collapsed(found)
    }

    static func collapsed(_ devices: [ADBDevice]) -> [ADBDevice] {
        let ipPorts = Set(devices.filter { $0.isWireless && !$0.isMDNSHostname }.compactMap(\.wirelessPort))
        let withoutAliases = devices.filter { device in
            guard device.isMDNSHostname, let port = device.wirelessPort else { return true }
            return !ipPorts.contains(port)
        }
        let wirelessModels = Set(
            withoutAliases
                .filter { $0.isWireless && !$0.isMDNSHostname && !$0.model.isEmpty }
                .map(\.model)
        )
        let withoutUSBDupes = withoutAliases.filter { device in
            if device.isWireless { return true }
            if device.model.isEmpty { return true }
            return !wirelessModels.contains(device.model)
        }
        var best: [String: ADBDevice] = [:]
        for device in withoutUSBDupes {
            let key = device.hardware.isEmpty ? (device.model.isEmpty ? device.serial : device.model) : device.hardware
            if let existing = best[key] {
                if rank(device) < rank(existing) {
                    best[key] = device
                }
            } else {
                best[key] = device
            }
        }
        return withoutUSBDupes.filter { device in
            best.values.contains(device)
        }
    }

    private static func rank(_ device: ADBDevice) -> Int {
        if device.isWireless && !device.isMDNSHostname { return 0 }
        if !device.isWireless { return 1 }
        return 2
    }

    static func pair(path: String, host: String, port: Int, password: String) -> (ok: Bool, output: String) {
        let result = Shell.run(
            executable: path,
            arguments: ["pair", "\(host):\(port)", password],
            timeout: 20
        )
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return (output.localizedCaseInsensitiveContains("successfully paired"), output)
    }

    static func connect(path: String, host: String, port: Int) -> (ok: Bool, output: String) {
        let result = Shell.run(
            executable: path,
            arguments: ["connect", "\(host):\(port)"],
            timeout: 12
        )
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = output.localizedCaseInsensitiveContains("connected to")
            || output.localizedCaseInsensitiveContains("already connected")
        return (ok, output)
    }

    static func disconnect(path: String, serial: String) {
        _ = Shell.run(executable: path, arguments: ["disconnect", serial], timeout: 8)
    }

    static func startServer(path: String) {
        _ = Shell.run(executable: path, arguments: ["start-server"], timeout: 10)
    }

    static func mdnsServices(path: String) -> [(name: String, type: String, address: String)] {
        let result = Shell.run(executable: path, arguments: ["mdns", "services"], timeout: 6)
        var rows: [(String, String, String)] = []
        for raw in result.output.split(separator: "\n") {
            let line = String(raw)
            let type: String
            if line.contains("_adb-tls-pairing._tcp") {
                type = "_adb-tls-pairing._tcp"
            } else if line.contains("_adb-tls-connect._tcp") {
                type = "_adb-tls-connect._tcp"
            } else {
                continue
            }
            guard let range = line.range(of: type) else { continue }
            let name = line[..<range.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: \.isWhitespace)
                .last
                .map(String.init) ?? ""
            let address = line[range.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: \.isWhitespace)
                .first
                .map(String.init) ?? ""
            guard address.contains(":") else { continue }
            rows.append((name, type, address))
        }
        return rows
    }
}

enum MDNSResolve {
    static func pairing(instance: String) -> PairingTarget? {
        let result = Shell.run(
            executable: "/usr/bin/dns-sd",
            arguments: ["-t", "2", "-L", instance, "_adb-tls-pairing._tcp", "local."],
            timeout: 4
        )
        return parse(instance: instance, output: result.output)
    }

    static func connect(instance: String) -> PairingTarget? {
        let result = Shell.run(
            executable: "/usr/bin/dns-sd",
            arguments: ["-t", "2", "-L", instance, "_adb-tls-connect._tcp", "local."],
            timeout: 4
        )
        return parse(instance: instance, output: result.output)
    }

    private static func parse(instance: String, output: String) -> PairingTarget? {
        guard let line = output.split(separator: "\n").first(where: { $0.contains("can be reached at") }) else {
            return nil
        }
        let marker = "can be reached at"
        guard let range = line.range(of: marker) else { return nil }
        var rest = line[range.upperBound...]
            .trimmingCharacters(in: .whitespaces)
        if let paren = rest.firstIndex(of: "(") {
            rest = rest[..<paren].trimmingCharacters(in: .whitespaces)
        }
        rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard let colon = rest.lastIndex(of: ":"),
              let port = Int(rest[rest.index(after: colon)...])
        else { return nil }
        let hostPart = String(rest[..<colon]).replacingOccurrences(of: ".:", with: "")
        let host = Shell.ipv4(for: hostPart) ?? hostPart.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return PairingTarget(name: instance, host: host, port: port)
    }
}

final class DNSBrowse {
    private var process: Process?
    private var handle: FileHandle?

    func start(type: String, onAdd: @escaping (String) -> Void) {
        stop()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/dns-sd")
        proc.arguments = ["-B", type, "local."]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        let file = pipe.fileHandleForReading
        file.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for raw in text.split(separator: "\n") {
                let line = String(raw)
                guard line.contains("Add"), line.contains(type) else { continue }
                guard let name = line.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) else { continue }
                if name.isEmpty || name == "Name" || name == "local." { continue }
                DispatchQueue.main.async { onAdd(name) }
            }
        }
        do {
            try proc.run()
            process = proc
            handle = file
        } catch {
            handle = nil
            process = nil
        }
    }

    func stop() {
        handle?.readabilityHandler = nil
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        handle = nil
    }
}

enum PairingCode {
    static func randomName() -> String {
        "studio-" + random(length: 10, from: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    }

    static func randomPassword() -> String {
        random(length: 8, from: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    }

    static func payload(name: String, password: String) -> String {
        "WIFI:T:ADB;S:\(name);P:\(password);;"
    }

    private static func random(length: Int, from alphabet: String) -> String {
        String((0..<length).compactMap { _ in alphabet.randomElement() })
    }
}
