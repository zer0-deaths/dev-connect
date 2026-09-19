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
    static func listPhysical() -> [IOSDevice] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("adb-pair-ios-devices.json")
        _ = Shell.run(
            executable: "/usr/bin/xcrun",
            arguments: [
                "devicectl", "list", "devices",
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

    static func pair(identifier: String) -> (ok: Bool, output: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("adb-pair-ios-pair.json")
        let result = Shell.run(
            executable: "/usr/bin/xcrun",
            arguments: [
                "devicectl", "manage", "pair",
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

    static func unpair(identifier: String) -> (ok: Bool, output: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("adb-pair-ios-unpair.json")
        let result = Shell.run(
            executable: "/usr/bin/xcrun",
            arguments: [
                "devicectl", "manage", "unpair",
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
        if result.status == 0
            || output.localizedCaseInsensitiveContains("unpair") {
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
