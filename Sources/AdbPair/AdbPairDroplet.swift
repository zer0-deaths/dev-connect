import Combine
import DroppyKit
import SwiftUI

@objc(AdbPairPrincipal)
public final class AdbPairPrincipal: NSObject, DropletPrincipal {
    public override init() { super.init() }

    @MainActor public func makeDroplet() -> AnyObject { AdbPairDroplet() }
}

@MainActor
public final class AdbPairDroplet: NSObject, ObservableObject, Droplet {
    public nonisolated static let id: DropletID = "adb-pair"

    private var host: DropletHost?
    private var pollTimer: AnyCancellable?
    private var pairingBrowse = DNSBrowse()
    private var connectBrowse = DNSBrowse()
    private var pairingTask: Task<Void, Never>?
    private var pairPoll: AnyCancellable?
    private var seenPairing: Set<String> = []
    private var expectedConnectIP: String?

    @Published var devices: [ADBDevice] = []
    @Published var pairingTargets: [PairingTarget] = []
    @Published var connectTargets: [PairingTarget] = []
    @Published var status: String = "Ready"
    @Published var mode: PairMode = .qr
    @Published var qrName: String = ""
    @Published var qrPassword: String = ""
    @Published var qrImage: CGImage?
    @Published var pairingCode: String = ""
    @Published var manualHost: String = ""
    @Published var selectedTargetID: String?
    @Published var isPairing: Bool = false
    @Published var addFlow: AddFlow = .idle

    var isPairingOpen: Bool { addFlow == .qr || addFlow == .code }
    @Published var lastError: String?
    @Published var resolvedADBPath: String = ""
    @Published var platform: DevicePlatform = .android
    @Published var iosDevices: [IOSDevice] = []
    @Published var pendingUnpair: PendingUnpair?
    @Published var measuredHeight: CGFloat = 0

    var adbOverride: String {
        get { host?.preferences.value(forKey: "adbPath", default: "") ?? "" }
        set { host?.preferences.setValue(newValue, forKey: "adbPath") }
    }

    public func activate(host: DropletHost) throws {
        self.host = host
        rotateQR()
        refreshADBPath()
        if let path = ADBPath.detect(override: adbOverride) {
            Task.detached { ADB.startServer(path: path) }
        }
        refreshDevices()
        pollTimer = Timer.publish(every: 2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshDevices()
                self?.pollADBMdns()
                self?.refreshIOSDevices()
            }
        pollADBMdns()
        refreshIOSDevices()
        host.log.info("Dev Connect activated adb=\(resolvedADBPath.isEmpty ? "missing" : resolvedADBPath)")
    }

    public func deactivate() {
        pairingTask?.cancel()
        pairingTask = nil
        pairPoll?.cancel()
        pairPoll = nil
        pollTimer?.cancel()
        pollTimer = nil
        pairingBrowse.stop()
        connectBrowse.stop()
        _ = host?.shelf.setHoldsOpen(false)
        host = nil
    }

    func refreshADBPath() {
        resolvedADBPath = ADBPath.detect(override: adbOverride) ?? ""
    }

    func refreshIOSDevices() {
        Task { [weak self] in
            let found = await Task.detached { DeviceCtl.listPhysical() }.value
            guard let self else { return }
            let changed = found != self.iosDevices
            self.iosDevices = found
            if changed, self.platform == .ios { self.refreshWidgetLayout() }
        }
    }

    func selectPlatform(_ platform: DevicePlatform) {
        if self.platform == platform { return }
        self.platform = platform
        lastError = nil
        resetMeasuredHeight()
        if platform == .ios {
            dismissPairing()
            refreshIOSDevices()
        }
        refreshWidgetLayout()
    }

    func requestUnpairAndroid(_ device: ADBDevice) {
        pendingUnpair = .android(device.serial)
    }

    func requestUnpairIOS(_ device: IOSDevice) {
        pendingUnpair = .ios(device.id)
    }

    func cancelUnpair() {
        pendingUnpair = nil
    }

    func confirmUnpair() {
        switch pendingUnpair {
        case .android(let serial):
            pendingUnpair = nil
            if let device = devices.first(where: { $0.serial == serial }) {
                disconnect(device)
                presentHUD(text: "Disconnected", detail: device.title)
            }
        case .ios(let id):
            pendingUnpair = nil
            if let device = iosDevices.first(where: { $0.id == id }) {
                unpairIOS(device)
            }
        case .none:
            break
        }
    }

    func handleIOS(_ device: IOSDevice) {
        pendingUnpair = nil
        guard device.canPair else {
            presentHUD(text: device.trailing, detail: device.title)
            return
        }
        lastError = nil
        isPairing = true
        status = "Tap Trust on the iPhone"
        presentHUD(text: "Tap Trust", detail: device.title)
        host?.log.info("ios pair \(device.udid)")
        Task { [weak self] in
            let result = await Task.detached { DeviceCtl.pair(identifier: device.udid) }.value
            guard let self else { return }
            self.isPairing = false
            self.host?.log.info("ios pair -> \(result.output)")
            self.refreshIOSDevices()
            if result.ok {
                self.status = "Paired \(device.title)"
                self.presentHUD(text: "Paired", detail: device.title)
            } else {
                let message = result.output.isEmpty
                    ? "Pair failed. Plug in USB and tap Trust."
                    : result.output
                self.lastError = message
                self.status = message
                self.presentHUD(text: "Failed", detail: device.title)
            }
        }
    }

    func unpairIOS(_ device: IOSDevice) {
        lastError = nil
        isPairing = true
        status = "Unpairing \(device.title)"
        presentHUD(text: "Unpairing", detail: device.title)
        host?.log.info("ios unpair \(device.udid)")
        Task { [weak self] in
            let result = await Task.detached { DeviceCtl.unpair(identifier: device.udid) }.value
            guard let self else { return }
            self.isPairing = false
            self.host?.log.info("ios unpair -> \(result.output)")
            self.refreshIOSDevices()
            if result.ok {
                self.status = "Unpaired \(device.title)"
                self.presentHUD(text: "Unpaired", detail: device.title)
            } else {
                let message = result.output.isEmpty ? "Unpair failed." : result.output
                self.lastError = message
                self.status = message
                self.presentHUD(text: "Failed", detail: device.title)
            }
        }
    }

    func refreshDevices() {
        refreshADBPath()
        guard !resolvedADBPath.isEmpty else {
            devices = []
            return
        }
        let path = resolvedADBPath
        Task { [weak self] in
            let found = await Task.detached { ADB.devices(path: path) }.value
            guard let self else { return }
            self.devices = found
        }
    }

    func rotateQR() {
        qrName = PairingCode.randomName()
        qrPassword = PairingCode.randomPassword()
        qrImage = QRCodeImage.make(PairingCode.payload(name: qrName, password: qrPassword))
        seenPairing.removeAll()
        status = "Waiting for a scan"
        lastError = nil
    }

    func beginAddDevice() {
        lastError = nil
        resetMeasuredHeight()
        addFlow = platform == .ios ? .iosHelp : .pickAndroid
        _ = host?.shelf.open(revealing: "adb-pair")
        _ = host?.shelf.setHoldsOpen(true)
        refreshWidgetLayout()
    }

    func presentPairing(_ mode: PairMode) {
        self.mode = mode
        lastError = nil
        pairingCode = ""
        resetMeasuredHeight()
        addFlow = mode == .qr ? .qr : .code
        if mode == .qr {
            if qrName.isEmpty { rotateQR() }
            status = "Waiting for a scan"
            startQRWait()
        } else {
            status = "On the phone, tap Pair device with pairing code"
            startCodeWait()
        }
        host?.log.info("pairing \(mode.rawValue)")
        _ = host?.shelf.open(revealing: "adb-pair")
        _ = host?.shelf.setHoldsOpen(true)
        refreshWidgetLayout()
        presentHUD(text: mode == .qr ? "Scan QR" : "Enter code", detail: "Dev Connect")
    }

    var cardHeight: CGFloat {
        let measured = measuredHeight
        if measured >= 48 { return min(measured, 480) }
        return min(max(estimatedHeight, 48), 480)
    }

    var estimatedHeight: CGFloat {
        switch addFlow {
        case .pickAndroid:
            return 240
        case .iosHelp:
            return 340
        case .qr:
            return 280
        case .code:
            if pairingTargets.isEmpty { return 220 }
            let found = CGFloat(min(pairingTargets.count, 4))
            return min(200 + found * 52 + 200, 480)
        case .idle:
            if platform == .ios {
                let extra = CGFloat(min(max(iosDevices.count, 1), 3))
                return 180 + extra * 52
            }
            let extra = CGFloat(min(max(nearbyPhones.count + devices.count, 1), 3))
            return 180 + extra * 48
        }
    }

    func updateMeasuredHeight(_ height: CGFloat) {
        let clamped = min(max(height.rounded(), 48), 480)
        guard abs(clamped - measuredHeight) > 1 else { return }
        measuredHeight = clamped
        refreshWidgetLayout()
    }

    func resetMeasuredHeight() {
        measuredHeight = 0
    }

    var pendingConnect: [PairingTarget] {
        connectTargets.filter { target in
            !devices.contains { $0.serial.hasPrefix("\(target.host):") }
        }
    }

    var nearbyPhones: [NearbyPhone] {
        var pairingByHost: [String: PairingTarget] = [:]
        var connectByHost: [String: PairingTarget] = [:]
        for target in pairingTargets { pairingByHost[target.host] = target }
        for target in connectTargets { connectByHost[target.host] = target }
        let hosts = Set(pairingByHost.keys).union(connectByHost.keys)
        return hosts.sorted().compactMap { host in
            if devices.contains(where: { $0.serial.hasPrefix("\(host):") && $0.isReady }) {
                return nil
            }
            return NearbyPhone(host: host, pairing: pairingByHost[host], connect: connectByHost[host])
        }
    }

    func handleNearby(_ phone: NearbyPhone) {
        if let pairing = phone.pairing {
            selectedTargetID = pairing.id
            presentPairing(.code)
            presentHUD(text: "Enter code", detail: phone.host)
            return
        }
        if let connect = phone.connect {
            connectNearby(connect)
        }
    }

    func appendDigit(_ digit: String) {
        guard pairingCode.count < 6 else { return }
        pairingCode += digit
        if pairingCode.count == 6 {
            Task { await pairEnteredCode() }
        }
    }

    func deleteDigit() {
        if !pairingCode.isEmpty {
            pairingCode.removeLast()
        }
    }

    func selectTarget(_ target: PairingTarget) {
        selectedTargetID = target.id
        if pairingCode.count == 6 {
            Task { await pairEnteredCode() }
        }
    }

    func connectNearby(_ target: PairingTarget) {
        lastError = nil
        status = "Connecting \(target.host)"
        presentHUD(text: "Connecting", detail: target.host)
        host?.log.info("connect tap \(target.host):\(target.port)")
        Task { await connect(target: target) }
    }

    func dismissPairing() {
        stopWaiting()
        addFlow = .idle
        resetMeasuredHeight()
        _ = host?.shelf.setHoldsOpen(false)
        refreshWidgetLayout()
    }

    func refreshWidgetLayout() {
        host?.shelf.invalidateLayout(for: "adb-pair")
    }

    func applyPairingCode(_ raw: String) {
        let digits = String(raw.filter(\.isNumber).prefix(6))
        pairingCode = digits
        if digits.count == 6 {
            Task { await pairEnteredCode() }
        }
    }

    func pairEnteredCode() async {
        let code = pairingCode
        guard code.count == 6, !isPairing else { return }
        if let target = currentTarget() {
            await pair(target: target, password: code)
            return
        }
        if let manual = parseManualHost() {
            await pair(target: manual, password: code)
            return
        }
        lastError = "Waiting for the phone. Open Pair device with pairing code."
    }

    func pairManual() async {
        guard let target = parseManualHost() else {
            lastError = "Type the phone IP and pairing port, like 192.168.1.12:37123"
            return
        }
        let password = pairingCode
        guard password.count >= 6 else {
            lastError = "Type the 6-digit pairing code"
            return
        }
        await pair(target: target, password: password)
    }

    func disconnect(_ device: ADBDevice) {
        guard device.isWireless, !resolvedADBPath.isEmpty else { return }
        let path = resolvedADBPath
        let serial = device.serial
        Task {
            await Task.detached { ADB.disconnect(path: path, serial: serial) }.value
            refreshDevices()
        }
    }

    private func startQRWait() {
        stopWaiting()
        seenPairing.removeAll()
        expectedConnectIP = nil
        pairingBrowse.start(type: "_adb-tls-pairing._tcp") { [weak self] name in
            self?.handlePairingInstance(name)
        }
        startPairPoll()
    }

    private func startCodeWait() {
        stopWaiting()
        seenPairing.removeAll()
        if selectedTargetID == nil {
            selectedTargetID = pairingTargets.first?.id
        }
        pairingBrowse.start(type: "_adb-tls-pairing._tcp") { [weak self] name in
            self?.handlePairingInstance(name)
        }
        startPairPoll()
    }

    private func startPairPoll() {
        pairPoll?.cancel()
        pollADBMdns()
        pairPoll = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.pollADBMdns()
            }
    }

    private func stopWaiting() {
        pairingTask?.cancel()
        pairingTask = nil
        pairPoll?.cancel()
        pairPoll = nil
        pairingBrowse.stop()
        connectBrowse.stop()
        isPairing = false
    }

    private func handlePairingInstance(_ name: String) {
        if mode == .qr, name != qrName, !name.hasPrefix(qrName) { return }
        guard seenPairing.insert(name).inserted else { return }
        pairingTask = Task { [weak self] in
            let resolved = await Task.detached { MDNSResolve.pairing(instance: name) }.value
            guard let self, let resolved else { return }
            if Task.isCancelled { return }
            if self.mode == .qr {
                await self.pair(target: resolved, password: self.qrPassword)
            } else {
                if !self.pairingTargets.contains(resolved) {
                    self.pairingTargets.append(resolved)
                    self.refreshWidgetLayout()
                }
                if self.selectedTargetID == nil {
                    self.selectedTargetID = resolved.id
                }
                if self.pairingCode.count == 6 {
                    await self.pairEnteredCode()
                }
            }
        }
    }

    private func pollADBMdns() {
        guard !resolvedADBPath.isEmpty else { return }
        let path = resolvedADBPath
        Task { [weak self] in
            let rows = await Task.detached { ADB.mdnsServices(path: path) }.value
            guard let self else { return }
            var pairing: [PairingTarget] = []
            var connect: [PairingTarget] = []
            for row in rows {
                let parts = row.address.split(separator: ":")
                guard parts.count == 2, let port = Int(parts[1]) else { continue }
                let target = PairingTarget(name: row.name, host: String(parts[0]), port: port)
                if row.type.contains("pairing") {
                    pairing.append(target)
                } else if row.type.contains("tls-connect") {
                    connect.append(target)
                }
            }
            let changed = connect != self.connectTargets || pairing != self.pairingTargets
            self.connectTargets = connect
            self.pairingTargets = pairing
            if self.selectedTargetID == nil {
                self.selectedTargetID = pairing.first?.id
            }
            if changed { self.refreshWidgetLayout() }
            if self.isPairingOpen, self.mode == .qr {
                for target in pairing where target.name == self.qrName || target.name.hasPrefix(self.qrName) {
                    await self.pair(target: target, password: self.qrPassword)
                    return
                }
            } else if self.isPairingOpen, self.mode == .code {
                if !pairing.isEmpty, self.pairingCode.count == 6 {
                    await self.pairEnteredCode()
                }
            }
        }
    }

    private func pair(target: PairingTarget, password: String) async {
        guard !isPairing else { return }
        refreshADBPath()
        guard !resolvedADBPath.isEmpty else {
            lastError = "ADB was not found. Set the path in Settings."
            return
        }
        isPairing = true
        lastError = nil
        status = "Pairing \(target.host):\(target.port)"
        let path = resolvedADBPath
        let result = await Task.detached {
            ADB.pair(path: path, host: target.host, port: target.port, password: password)
        }.value
        host?.log.info("adb pair \(target.host):\(target.port) -> \(result.output)")
        guard result.ok else {
            isPairing = false
            lastError = result.output.isEmpty ? "Pairing failed" : result.output
            status = "Pairing failed"
            return
        }
        expectedConnectIP = target.host
        status = "Paired. Connecting"
        presentHUD(text: "Paired", detail: target.host)
        await connectAfterPair(ip: target.host)
    }

    private func connectAfterPair(ip: String) async {
        refreshADBPath()
        let path = resolvedADBPath
        connectBrowse.start(type: "_adb-tls-connect._tcp") { [weak self] name in
            Task { [weak self] in
                let resolved = await Task.detached { MDNSResolve.connect(instance: name) }.value
                guard let self, let resolved else { return }
                if resolved.host == ip || self.expectedConnectIP == nil {
                    await self.connect(target: resolved)
                }
            }
        }
        for _ in 0..<20 {
            if Task.isCancelled { return }
            let rows = await Task.detached { ADB.mdnsServices(path: path) }.value
            if let row = rows.first(where: { $0.type.contains("_adb-tls-connect") && $0.address.hasPrefix(ip) }) {
                let parts = row.address.split(separator: ":")
                if parts.count == 2, let port = Int(parts[1]) {
                    await connect(target: PairingTarget(name: row.name, host: String(parts[0]), port: port))
                    return
                }
            }
            let found = await Task.detached { ADB.devices(path: path) }.value
            devices = found
            if found.contains(where: { $0.isWireless && $0.isReady }) {
                finishConnected()
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        isPairing = false
        status = "Paired. If it does not show up, toggle Wireless debugging."
        refreshDevices()
    }

    private func connect(target: PairingTarget) async {
        refreshADBPath()
        guard !resolvedADBPath.isEmpty else {
            lastError = "ADB not found"
            status = "ADB not found"
            presentHUD(text: "No ADB", detail: "")
            return
        }
        let path = resolvedADBPath
        let result = await Task.detached {
            ADB.connect(path: path, host: target.host, port: target.port)
        }.value
        host?.log.info("adb connect \(target.host):\(target.port) -> \(result.output)")
        refreshDevices()
        if result.ok {
            finishConnected()
            return
        }
        if let pairing = pairingTargets.first(where: { $0.host == target.host }) {
            selectedTargetID = pairing.id
            presentPairing(.code)
            lastError = "Need the 6-digit pairing code"
            status = "Need the 6-digit pairing code"
            presentHUD(text: "Pair first", detail: target.host)
            return
        }
        let message = result.output.isEmpty ? "Connect failed. Pair with QR." : result.output
        lastError = message
        status = message
        presentHUD(text: "Failed", detail: target.host)
        presentPairing(.qr)
    }

    private func finishConnected() {
        isPairing = false
        addFlow = .idle
        resetMeasuredHeight()
        status = "Connected"
        presentHUD(text: "Connected", detail: devices.first(where: { $0.isReady })?.title ?? "Android")
        stopWaiting()
        _ = host?.shelf.setHoldsOpen(false)
        refreshWidgetLayout()
        refreshDevices()
    }

    private func presentHUD(text: String, detail: String) {
        let request = DropletHUDRequest(
            id: "adb-pair.status",
            duration: 2.4,
            priority: .high,
            accessibilityLabel: "\(text) \(detail)"
        ) {
            HStack(spacing: 0) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: DroppyLiveActivityMetrics.iconSize, weight: .semibold))
                Spacer(minLength: 0)
                Text(verbatim: text)
                    .font(.system(size: DroppyLiveActivityMetrics.labelFontSize, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
        }
        _ = host?.hud.present(request)
    }

    private func currentTarget() -> PairingTarget? {
        if let id = selectedTargetID {
            return pairingTargets.first(where: { $0.id == id })
        }
        return pairingTargets.count == 1 ? pairingTargets.first : nil
    }

    private func parseManualHost() -> PairingTarget? {
        let raw = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = raw.replacingOccurrences(of: " ", with: "")
        guard let colon = cleaned.lastIndex(of: ":"),
              let port = Int(cleaned[cleaned.index(after: colon)...])
        else { return nil }
        let host = String(cleaned[..<colon])
        guard !host.isEmpty, port > 0 else { return nil }
        return PairingTarget(name: "manual", host: host, port: port)
    }
}

extension AdbPairDroplet: ShelfWidgetProviding {
    public var widgetDescriptors: [ShelfWidgetDescriptor] {
        [
            ShelfWidgetDescriptor(
                id: "adb-pair",
                title: "Dev Connect",
                systemImage: "link",
                layoutTraits: ShelfWidgetLayoutTraits(
                    preferredSoloWidth: 420,
                    preferredPairedWidth: 210,
                    contentHeight: .fixed(cardHeight)
                ),
                focusPolicy: .keyboardFocusable,
                searchKeywords: ["adb", "android", "pair", "qr", "wireless"]
            )
        ]
    }

    public func makeWidgetView(_ id: ShelfWidgetID, context: ShelfWidgetContext) -> AnyView {
        AnyView(AdbPairWidget(droplet: self, context: context))
    }

    public func makeWidgetSettingsPopover(_ id: ShelfWidgetID) -> AnyView? { nil }
}

private struct AdbPairWidget: View {
    @ObservedObject var droplet: AdbPairDroplet
    let context: ShelfWidgetContext

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            header
            platformToggle
            content
        }
        .padding(context.contentInsets)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: DevConnectHeightKey.self, value: geo.size.height)
            }
        )
        .onPreferenceChange(DevConnectHeightKey.self) { droplet.updateMeasuredHeight($0) }
    }

    private var header: some View {
        HStack(spacing: DroppySpacing.xsm) {
            Text("Dev Connect")
                .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: DroppySpacing.md)
            headerActions
        }
        .frame(minHeight: 20)
        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
    }

    private var headerActions: some View {
        Button {
            droplet.dismissPairing()
        } label: {
            Image(systemName: "xmark")
        }
        .buttonStyle(DroppyCircleButtonStyle(size: 20))
        .help("Close")
        .accessibilityLabel("Close")
        .opacity(droplet.addFlow == .idle ? 0 : 1)
        .allowsHitTesting(droplet.addFlow != .idle)
        .frame(width: 20, height: 20)
    }

    private var platformToggle: some View {
        HStack(spacing: 0) {
            toggleHalf("Android", .android)
            toggleHalf("iOS", .ios)
        }
        .frame(height: 28)
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: DroppyRadius.small, style: .continuous)
                .fill(AdaptiveColors.notchSurfaceCardFill)
        )
        .clipShape(RoundedRectangle(cornerRadius: DroppyRadius.small, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Platform")
    }

    private func toggleHalf(_ title: String, _ platform: DevicePlatform) -> some View {
        let selected = droplet.platform == platform
        return Button {
            droplet.selectPlatform(platform)
        } label: {
            Text(verbatim: title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected
                    ? AdaptiveColors.notchSurfacePrimaryText
                    : AdaptiveColors.notchSurfaceTertiaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: DroppyRadius.xs, style: .continuous)
                        .fill(selected ? AdaptiveColors.notchSurfaceCardHoverFill : Color.white.opacity(0.001))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var content: some View {
        switch droplet.addFlow {
        case .pickAndroid:
            androidMethodPicker
        case .qr:
            widgetQR
        case .code:
            widgetCode
        case .iosHelp:
            iosHelp
        case .idle:
            if droplet.platform == .ios {
                iosList
            } else if droplet.resolvedADBPath.isEmpty {
                AdbCaption("ADB not found. Set the path in Settings.")
            } else {
                idleList
            }
        }
    }

    private var androidMethodPicker: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            AdbCaption("Choose how to add this Android.")
            Button {
                droplet.presentPairing(.qr)
            } label: {
                AdbDeviceChip(title: "QR code", subtitle: "Scan from Wireless debugging.", chevron: true)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            Button {
                droplet.presentPairing(.code)
            } label: {
                AdbDeviceChip(title: "Pairing code", subtitle: "6-digit code from the phone.", chevron: true)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        }
    }

    private var iosHelp: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            AdbCaption("iPhone has no QR pair. Use USB.")
            AdbDeviceChip(title: "1. Plug in", subtitle: "USB cable to this Mac.")
            AdbDeviceChip(title: "2. Unlock", subtitle: "Open the phone and keep it awake.")
            AdbDeviceChip(title: "3. Trust", subtitle: "Tap Trust, then Pair on the row above.")
        }
    }

    private var iosList: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xsm) {
            if droplet.iosDevices.isEmpty {
                AdbCaption(context.isCompact ? "No iPhones" : "No physical iOS devices found.")
            } else if context.isCompact, let device = droplet.iosDevices.first {
                iosRow(device)
            } else {
                ForEach(droplet.iosDevices.prefix(3)) { device in
                    iosRow(device)
                }
            }
            if let error = droplet.lastError, !error.isEmpty {
                AdbCaption(error)
            }
            addDeviceButton
        }
    }

    @ViewBuilder
    private func iosRow(_ device: IOSDevice) -> some View {
        if device.isPaired {
            AdbDeviceChip(
                title: device.title,
                subtitle: device.subtitle,
                selected: true,
                trailing: "Unpair",
                trailingAction: { droplet.requestUnpairIOS(device) },
                destructive: true,
                pendingConfirm: droplet.pendingUnpair == .ios(device.id),
                onConfirm: { droplet.confirmUnpair() },
                onCancel: { droplet.cancelUnpair() }
            )
        } else if device.canPair {
            AdbDeviceChip(
                title: device.title,
                subtitle: device.subtitle,
                trailing: droplet.isPairing ? "Trust" : "Pair",
                trailingAction: { droplet.handleIOS(device) }
            )
        } else {
            AdbDeviceChip(
                title: device.title,
                subtitle: device.subtitle,
                trailing: device.trailing
            )
        }
    }

    @ViewBuilder
    private func androidRow(_ device: ADBDevice, compact: Bool) -> some View {
        if device.isWireless {
            AdbDeviceChip(
                title: device.title,
                subtitle: compact ? nil : device.serial,
                selected: device.isReady,
                trailing: "Unpair",
                trailingAction: { droplet.requestUnpairAndroid(device) },
                destructive: true,
                pendingConfirm: droplet.pendingUnpair == .android(device.serial),
                onConfirm: { droplet.confirmUnpair() },
                onCancel: { droplet.cancelUnpair() }
            )
        } else {
            AdbDeviceChip(
                title: device.title,
                subtitle: compact ? nil : "USB",
                selected: device.isReady,
                trailing: "USB"
            )
        }
    }

    private var idleList: some View {
        VStack(spacing: DroppySpacing.xsm) {
            if !droplet.nearbyPhones.isEmpty, !context.isCompact {
                ForEach(droplet.nearbyPhones.prefix(2)) { phone in
                    Button {
                        droplet.handleNearby(phone)
                    } label: {
                        AdbDeviceChip(
                            title: phone.host,
                            subtitle: phone.pairing.map { "port \(verbatimPort($0.port))" },
                            selected: false,
                            chevron: true
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            if context.isCompact, let device = droplet.devices.first {
                androidRow(device, compact: true)
            } else if !context.isCompact {
                ForEach(droplet.devices.prefix(3)) { device in
                    androidRow(device, compact: false)
                }
            }
            if droplet.devices.isEmpty && droplet.nearbyPhones.isEmpty {
                AdbCaption("No devices.")
            }
            if let error = droplet.lastError, !error.isEmpty {
                AdbCaption(error)
            }
            addDeviceButton
        }
    }

    private var addDeviceButton: some View {
        Button {
            droplet.beginAddDevice()
        } label: {
            HStack(spacing: DroppySpacing.sm) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                Text("Add new device")
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            }
            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            .padding(.horizontal, DroppySpacing.sm)
            .padding(.vertical, DroppySpacing.smd)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DroppyRadius.ms, style: .continuous)
                    .fill(AdaptiveColors.notchSurfaceCardFill)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add new device")
    }

    private var widgetQR: some View {
        HStack(alignment: .center, spacing: DroppySpacing.md) {
            AdbQRImage(image: droplet.qrImage, side: context.isCompact ? 96 : 128)
            VStack(alignment: .leading, spacing: DroppySpacing.sm) {
                Text("Waiting for a scan")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                AdbCaption("Wireless debugging, Pair device with QR code.")
                Button("Use a code") { droplet.presentPairing(.code) }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var widgetCode: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            if droplet.pairingTargets.isEmpty {
                AdbCaption("On the phone, tap Pair device with pairing code.")
                AdbDeviceChip(title: "Looking for a phone", subtitle: droplet.status)
            } else {
                AdbCaption("Enter the 6-digit code from the phone.")
                ForEach(droplet.pairingTargets.prefix(4)) { target in
                    Button {
                        droplet.selectTarget(target)
                    } label: {
                        AdbDeviceChip(
                            title: target.host,
                            subtitle: "port \(verbatimPort(target.port))",
                            selected: droplet.selectedTargetID == target.id,
                            chevron: true
                        )
                    }
                    .buttonStyle(.plain)
                }
                AdbPinDots(filled: droplet.pairingCode.count)
                AdbPinPad(enabled: !droplet.isPairing) { key in
                    switch key {
                    case "del": droplet.deleteDigit()
                    case "go": Task { await droplet.pairEnteredCode() }
                    default: droplet.appendDigit(key)
                    }
                }
            }
            if let error = droplet.lastError, !error.isEmpty {
                AdbCaption(error)
            }
            Button("Use a QR code") { droplet.presentPairing(.qr) }
                .buttonStyle(DroppyQuietButtonStyle(size: .small))
        }
    }
}

private func verbatimPort(_ port: Int) -> String {
    String(port)
}

private struct DevConnectHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct AdbCaption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 12))
            .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            .fixedSize(horizontal: false, vertical: true)
            .lineLimit(2)
    }
}

private struct AdbDeviceChip: View {
    let title: String
    let subtitle: String?
    var selected: Bool = false
    var trailing: String? = nil
    var trailingAction: (() -> Void)? = nil
    var chevron: Bool = false
    var destructive: Bool = false
    var pendingConfirm: Bool = false
    var onConfirm: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil

    private let dangerText = Color(red: 1, green: 0.45, blue: 0.45)
    private let dangerFill = Color(red: 1, green: 0.28, blue: 0.28).opacity(0.22)

    var body: some View {
        HStack(spacing: DroppySpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(verbatim: subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: DroppySpacing.md)
            trailingControl
        }
        .padding(.horizontal, DroppySpacing.sm)
        .padding(.vertical, DroppySpacing.smd)
        .background(
            RoundedRectangle(cornerRadius: DroppyRadius.ms, style: .continuous)
                .fill(selected
                      ? AdaptiveColors.notchSurfaceCardHoverFill
                      : AdaptiveColors.notchSurfaceCardFill)
        )
    }

    @ViewBuilder
    private var trailingControl: some View {
        if pendingConfirm {
            HStack(spacing: DroppySpacing.xs) {
                capsuleButton("Cancel", destructive: false, action: { onCancel?() })
                capsuleButton("Confirm", destructive: true, action: { onConfirm?() })
            }
        } else if let trailingAction, let trailing {
            capsuleButton(trailing, destructive: destructive, action: trailingAction)
        } else if chevron {
            Image(systemName: selected ? "checkmark" : "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
        } else if let trailing {
            Text(verbatim: trailing)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
        }
    }

    private func capsuleButton(_ title: String, destructive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            capsuleLabel(title, destructive: destructive)
        }
        .buttonStyle(.plain)
    }

    private func capsuleLabel(_ title: String, destructive: Bool) -> some View {
        Text(verbatim: title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(destructive ? dangerText : AdaptiveColors.notchSurfacePrimaryText)
            .padding(.horizontal, DroppySpacing.sm)
            .padding(.vertical, DroppySpacing.xs)
            .background(
                Capsule(style: .continuous)
                    .fill(destructive ? dangerFill : AdaptiveColors.notchSurfaceCardFill)
            )
    }
}

private struct AdbQRImage: View {
    let image: CGImage?
    let side: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.white
            }
        }
        .frame(width: side, height: side)
        .padding(10)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: DroppyRadius.medium, style: .continuous))
    }
}

private struct AdbPinDots: View {
    let filled: Int

    var body: some View {
        HStack(spacing: DroppySpacing.smd) {
            ForEach(0..<6, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(index < filled
                          ? AdaptiveColors.notchSurfacePrimaryText
                          : AdaptiveColors.notchSurfaceCardFill)
                    .frame(width: 16, height: 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DroppySpacing.xs)
    }
}

private struct AdbPinPad: View {
    let enabled: Bool
    let action: (String) -> Void
    private let keys = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["del", "0", "go"]]

    var body: some View {
        VStack(spacing: DroppySpacing.xsm) {
            ForEach(keys, id: \.self) { row in
                HStack(spacing: DroppySpacing.xsm) {
                    ForEach(row, id: \.self) { key in
                        Button {
                            action(key)
                        } label: {
                            padLabel(key)
                                .font(.system(size: 16, weight: key == "go" ? .semibold : .medium))
                                .frame(maxWidth: .infinity, minHeight: 36)
                                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                                .background(
                                    RoundedRectangle(cornerRadius: DroppyRadius.ms, style: .continuous)
                                        .fill(key == "go"
                                              ? AdaptiveColors.notchSurfaceCardHoverFill
                                              : AdaptiveColors.notchSurfaceCardFill)
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(!enabled && key != "del")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func padLabel(_ key: String) -> some View {
        switch key {
        case "del": Image(systemName: "delete.left")
        case "go": Image(systemName: "arrow.right")
        default: Text(verbatim: key)
        }
    }
}

extension AdbPairDroplet: HUDPresenting {}

extension AdbPairDroplet: SettingsPaneProviding {
    public func makeSettingsPane(context: SettingsPaneContext) -> AnyView {
        AnyView(AdbPairSettings(droplet: self))
    }

    public var settingsSearchEntries: [SettingsSearchEntry] {
        [SettingsSearchEntry(title: "Dev Connect", keywords: ["adb", "android", "ios", "iphone", "wireless", "qr"])]
    }
}

private struct AdbPairSettings: View {
    @ObservedObject var droplet: AdbPairDroplet
    @State private var pathDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.lg) {
            DropletSettingsCard {
                DropletControlRow(title: "ADB") {
                    DropletValuePill(text: droplet.resolvedADBPath.isEmpty ? "Not found" : URL(fileURLWithPath: droplet.resolvedADBPath).lastPathComponent)
                }
                DropletSettingsDivider()
                DropletStackedRow(
                    title: "Custom path",
                    infoTip: "Leave empty to use the Android SDK platform-tools binary."
                ) {
                    TextField("/path/to/adb", text: $pathDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { savePath() }
                }
                DropletSettingsDivider()
                DropletControlRow(title: "Devices") {
                    DropletValuePill(text: "\(droplet.devices.count)")
                }
                DropletSettingsDivider()
                DropletControlRow(title: "iOS") {
                    DropletValuePill(text: "\(droplet.iosDevices.count)")
                }
            }

            DropletSettingsCard {
                ForEach(Array(droplet.devices.enumerated()), id: \.element.id) { index, device in
                    if index > 0 { DropletSettingsDivider() }
                    DropletControlRow(title: device.title) {
                        HStack(spacing: DroppySpacing.sm) {
                            DropletValuePill(text: device.state)
                            if device.isWireless {
                                Button("Disconnect") { droplet.disconnect(device) }
                                    .buttonStyle(DroppyQuietButtonStyle(size: .small, destructive: true))
                            }
                        }
                    }
                }
                if droplet.devices.isEmpty {
                    DropletControlRow(title: "None connected") {
                        EmptyView()
                    }
                }
            }

            DropletSettingsCard {
                ForEach(Array(droplet.iosDevices.enumerated()), id: \.element.id) { index, device in
                    if index > 0 { DropletSettingsDivider() }
                    DropletControlRow(title: device.title) {
                        HStack(spacing: DroppySpacing.sm) {
                            DropletValuePill(text: device.trailing)
                            if device.isPaired {
                                Button("Unpair") { droplet.unpairIOS(device) }
                                    .buttonStyle(DroppyQuietButtonStyle(size: .small, destructive: true))
                            } else if device.canPair {
                                Button("Pair") { droplet.handleIOS(device) }
                                    .buttonStyle(DroppyQuietButtonStyle(size: .small))
                            }
                        }
                    }
                }
                if droplet.iosDevices.isEmpty {
                    DropletControlRow(title: "No iPhones") {
                        EmptyView()
                    }
                }
            }
        }
        .onAppear {
            pathDraft = droplet.adbOverride
            droplet.refreshDevices()
            droplet.refreshIOSDevices()
        }
        .onChange(of: pathDraft) { _, newValue in
            droplet.adbOverride = newValue
            droplet.refreshADBPath()
        }
    }

    private func savePath() {
        droplet.adbOverride = pathDraft
        droplet.refreshADBPath()
        droplet.refreshDevices()
    }
}
