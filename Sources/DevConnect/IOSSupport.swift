import Foundation

enum DevicePlatform: String, Equatable {
    case android
    case ios
}

enum AddFlow: Equatable {
    case idle
    case pickAndroid
    case qr
    case code
    case iosHelp
}

enum PendingUnpair: Equatable {
    case android(String)
    case ios(String)
}

struct IOSDevice: Identifiable, Equatable {
    let id: String
    let udid: String
    let name: String
    let model: String
    let pairingState: String
    let transport: String
    let connectionState: String
    let isSimulator: Bool

    var title: String { name.isEmpty ? model : name }
    var isPaired: Bool { pairingState == "paired" }
    var canPair: Bool { !isSimulator && !isPaired }
    var subtitle: String {
        var parts: [String] = []
        if !model.isEmpty { parts.append(model) }
        switch transport {
        case "wired": parts.append("USB")
        case "localNetwork": parts.append("Wi-Fi")
        default: break
        }
        return parts.joined(separator: " · ")
    }
    var trailing: String {
        if isSimulator { return "Sim" }
        if !isPaired { return "Pair" }
        return "Unpair"
    }
}

enum DeviceCtl {
    /// Finds Xcode's `devicectl` on disk. Never runs the `/usr/bin/xcrun` shim
    /// unless a real Developer directory exists, because without one it asks
    /// the user to install the command line tools.
    static func resolve(developerDirs: [String] = defaultDeveloperDirs()) -> String? {
        let fm = FileManager.default
        for dir in developerDirs {
            for candidate in ["\(dir)/usr/bin/devicectl", "\(dir)/Contents/Developer/usr/bin/devicectl"]
            where fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        let hasXcodeDir = developerDirs.contains { dir in
            !dir.contains("CommandLineTools") && fm.fileExists(atPath: "\(dir)/usr/bin/xcodebuild")
        }
        guard hasXcodeDir, fm.isExecutableFile(atPath: "/usr/bin/xcrun") else { return nil }
        let found = Shell.run(executable: "/usr/bin/xcrun", arguments: ["--find", "devicectl"], timeout: 5)
        let path = found.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard found.status == 0, fm.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    static func defaultDeveloperDirs() -> [String] {
        var dirs: [String] = []
        if let env = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !env.isEmpty {
            dirs.append(env)
        }
        if let link = try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link") {
            dirs.append(link)
        }
        dirs.append("/Applications/Xcode.app/Contents/Developer")
        return dirs
    }

    static func listPhysical(path: String) -> [IOSDevice] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("adb-pair-ios-devices.json")
        try? FileManager.default.removeItem(at: url)
        _ = Shell.run(
            executable: path,
            arguments: [
                "list", "devices",
                "--omit-deprecated-fields-in-json",
                "--json-output", url.path
            ],
            timeout: 12
        )
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let devices = result["devices"] as? [[String: Any]]
        else { return [] }

        return devices.compactMap(parse).filter { !$0.isSimulator }
    }

    static func pair(path: String, identifier: String) -> (ok: Bool, output: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("adb-pair-ios-pair.json")
        try? FileManager.default.removeItem(at: url)
        let result = Shell.run(
            executable: path,
            arguments: [
                "manage", "pair",
                "--device", identifier,
                "--timeout", "60",
                "--json-output", url.path
            ],
            timeout: 70
        )
        var output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8) {
            output = output.isEmpty ? text : output + "\n" + text
        }
        if result.timedOut {
            return (false, output.isEmpty ? "Timed out." : output)
        }
        if result.status == 0
            || output.localizedCaseInsensitiveContains("\"pairingState\" : \"paired\"") {
            return (true, output)
        }
        let idevicepair = "/opt/homebrew/bin/idevicepair"
        guard FileManager.default.isExecutableFile(atPath: idevicepair) else {
            return (false, output.isEmpty ? "Pair failed. Plug in USB and tap Trust." : output)
        }
        let fallback = Shell.run(
            executable: idevicepair,
            arguments: ["pair", "-u", identifier],
            timeout: 20
        )
        let fallbackOut = fallback.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = fallback.status == 0
            || fallbackOut.localizedCaseInsensitiveContains("success")
        return (ok, fallbackOut.isEmpty ? output : fallbackOut)
    }

    static func unpair(path: String, identifier: String) -> (ok: Bool, output: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("adb-pair-ios-unpair.json")
        try? FileManager.default.removeItem(at: url)
        let result = Shell.run(
            executable: path,
            arguments: [
                "manage", "unpair",
                "--device", identifier,
                "--timeout", "20",
                "--json-output", url.path
            ],
            timeout: 25
        )
        var output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8) {
            output = output.isEmpty ? text : output + "\n" + text
        }
        if result.timedOut {
            return (false, output.isEmpty ? "Timed out." : output)
        }
        if result.status == 0 || outcomeSucceeded(url) {
            return (true, output)
        }
        let idevicepair = "/opt/homebrew/bin/idevicepair"
        guard FileManager.default.isExecutableFile(atPath: idevicepair) else {
            return (false, output.isEmpty ? "Unpair failed." : output)
        }
        let fallback = Shell.run(
            executable: idevicepair,
            arguments: ["unpair", "-u", identifier],
            timeout: 15
        )
        let fallbackOut = fallback.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = fallback.status == 0
            || fallbackOut.localizedCaseInsensitiveContains("success")
        return (ok, fallbackOut.isEmpty ? output : fallbackOut)
    }

    /// The JSON echoes the command's own arguments, so match the outcome
    /// field rather than searching the text for "unpair".
    private static func outcomeSucceeded(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = root["info"] as? [String: Any]
        else { return false }
        return (info["outcome"] as? String) == "success"
    }

    private static func parse(_ raw: [String: Any]) -> IOSDevice? {
        let properties = raw["properties"] as? [String: Any] ?? [:]
        let hardware = properties["hardware"] as? [String: Any] ?? [:]
        let connection = properties["connection"] as? [String: Any] ?? [:]
        let state = properties["state"] as? [String: Any] ?? [:]
        let reality = (hardware["reality"] as? String ?? "").lowercased()
        let isSimulator = reality == "simulated"
        let udid = hardware["udid"] as? String ?? ""
        let identifier = raw["identifier"] as? String ?? udid
        guard !identifier.isEmpty else { return nil }
        let name = (state["name"] as? String)
            ?? (hardware["marketingName"] as? String)
            ?? ""
        let model = displayModel(
            hardware["marketingName"] as? String
                ?? hardware["productType"] as? String
                ?? hardware["deviceType"] as? String
                ?? ""
        )
        return IOSDevice(
            id: identifier,
            udid: udid.isEmpty ? identifier : udid,
            name: name,
            model: model,
            pairingState: connection["pairingState"] as? String ?? "",
            transport: connection["transportType"] as? String ?? "",
            connectionState: connection["state"] as? String ?? "",
            isSimulator: isSimulator
        )
    }

    /// Apple product types use a comma (`iPhone18,1`). Show a dot instead.
    private static func displayModel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comma = trimmed.lastIndex(of: ",") else { return trimmed }
        let suffix = trimmed[trimmed.index(after: comma)...]
        guard suffix.allSatisfy(\.isNumber), !suffix.isEmpty else { return trimmed }
        return trimmed.replacingOccurrences(of: ",", with: ".")
    }
}
