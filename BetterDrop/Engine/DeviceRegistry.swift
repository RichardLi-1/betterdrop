import Foundation
import Network
import CryptoKit

// Discovers BetterDrop peers on the local network via Bonjour/mDNS.
// Also advertises this device so others can find it.
// Fires notifications when a device comes online or goes offline.

extension Notification.Name {
    static let deviceOnline  = Notification.Name("BetterDrop.deviceOnline")
    static let deviceOffline = Notification.Name("BetterDrop.deviceOffline")
}

@MainActor
final class DeviceRegistry: ObservableObject {
    static let shared = DeviceRegistry()

    // Stable UUID for this macOS install, persisted in UserDefaults
    let localDeviceID: UUID = {
        let key = "com.betterdrop.localDeviceID"
        if let stored = UserDefaults.standard.string(forKey: key),
           let uuid = UUID(uuidString: stored) { return uuid }
        let new = UUID()
        UserDefaults.standard.set(new.uuidString, forKey: key)
        return new
    }()

    @Published private(set) var knownDevices: [UUID: Device] = [:]
    @Published private(set) var onlineDeviceIDs: Set<UUID> = []

    private var browser: NWBrowser?
    private var listener: NWListener?
    private var pingTimers: [UUID: Timer] = [:]
    private var resolvedConnections: [UUID: NWConnection] = [:]

    private static let serviceType = "_betterdrop._tcp"
    private static let pingInterval: TimeInterval = 15
    private static let offlineThreshold: TimeInterval = 30

    // MARK: - Start / stop

    func startDiscovery() {
        startBrowsing()
        startAdvertising()
    }

    func stopDiscovery() {
        browser?.cancel()
        listener?.cancel()
        pingTimers.values.forEach { $0.invalidate() }
        pingTimers.removeAll()
        resolvedConnections.values.forEach { $0.cancel() }
        resolvedConnections.removeAll()
    }

    // MARK: - Browsing (finding others)

    private func startBrowsing() {
        let params = NWParameters()
        params.includePeerToPeer = true   // include AWDL

        let descriptor = NWBrowser.Descriptor.bonjour(type: Self.serviceType, domain: nil)
        browser = NWBrowser(for: descriptor, using: params)

        browser?.browseResultsChangedHandler = { [weak self] results, changes in
            guard let self else { return }
            Task { @MainActor in
                for change in changes {
                    switch change {
                    case .added(let result):
                        await self.handleDiscovered(result: result)
                    case .removed(let result):
                        await self.handleLost(result: result)
                    default:
                        break
                    }
                }
            }
        }

        browser?.start(queue: .global(qos: .utility))
    }

    // MARK: - Advertising (making ourselves findable)

    private func startAdvertising() {
        let params = NWParameters.tcp
        params.includePeerToPeer = true

        guard let listener = try? NWListener(using: params, on: TCPDirectTransport.port) else { return }
        self.listener = listener

        // Embed our device ID and public key in the TXT record
        let txtRecord = NWTXTRecord([
            "deviceID":   localDeviceID.uuidString,
            "name":       Host.current().localizedName ?? "Mac",
            "platform":   "macOS",
            "version":    "1",
        ])

        listener.service = NWListener.Service(
            name: localDeviceID.uuidString,
            type: Self.serviceType,
            txtRecord: txtRecord
        )

        listener.newConnectionHandler = { conn in
            conn.start(queue: .global(qos: .userInitiated))
            // Incoming transfers are handled by TCPDirectReceiver
        }

        listener.start(queue: .global(qos: .utility))
        self.listener = listener
    }

    // MARK: - Discovery events

    private func handleDiscovered(result: NWBrowser.Result) async {
        guard case .service(let name, _, _, _) = result.endpoint,
              let deviceID = UUID(uuidString: name) else { return }

        // Resolve to an endpoint for the transport layer
        let params = NWParameters()
        params.includePeerToPeer = true
        let conn = NWConnection(to: result.endpoint, using: params)
        resolvedConnections[deviceID] = conn

        TCPDirectTransport.resolvedEndpoints[deviceID] = result.endpoint

        markOnline(deviceID: deviceID, from: result)
    }

    private func handleLost(result: NWBrowser.Result) async {
        guard case .service(let name, _, _, _) = result.endpoint,
              let deviceID = UUID(uuidString: name) else { return }
        markOffline(deviceID: deviceID)
    }

    // MARK: - Online / offline state

    private func markOnline(deviceID: UUID, from result: NWBrowser.Result) {
        var device = knownDevices[deviceID] ?? Device(
            id: deviceID,
            name: txtValue(result, key: "name") ?? "Unknown Device",
            platform: DevicePlatform(rawValue: txtValue(result, key: "platform") ?? "") ?? .unknown,
            lastSeen: Date(),
            isOnline: true,
            avatarColor: CodableColor.presets[abs(deviceID.hashValue) % CodableColor.presets.count],
            isTrusted: false
        )
        device.isOnline = true
        device.lastSeen = Date()
        knownDevices[deviceID] = device

        if !onlineDeviceIDs.contains(deviceID) {
            onlineDeviceIDs.insert(deviceID)
            NotificationCenter.default.post(name: .deviceOnline, object: deviceID)
        }

        schedulePingExpiry(deviceID: deviceID)
    }

    private func markOffline(deviceID: UUID) {
        pingTimers[deviceID]?.invalidate()
        pingTimers.removeValue(forKey: deviceID)
        TCPDirectTransport.resolvedEndpoints.removeValue(forKey: deviceID)

        guard onlineDeviceIDs.contains(deviceID) else { return }
        onlineDeviceIDs.remove(deviceID)

        if var device = knownDevices[deviceID] {
            device.isOnline = false
            knownDevices[deviceID] = device
        }

        NotificationCenter.default.post(name: .deviceOffline, object: deviceID)
    }

    // If Bonjour doesn't fire a removal event (e.g. abrupt disconnect),
    // treat the device as offline after the threshold passes with no activity.
    private func schedulePingExpiry(deviceID: UUID) {
        pingTimers[deviceID]?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.offlineThreshold, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.markOffline(deviceID: deviceID) }
        }
        pingTimers[deviceID] = timer
    }

    // MARK: - AWDL reachability

    func isReachableViaAWDL(_ device: Device) -> Bool {
        // A device discovered via an AWDL-flagged interface was seen via AWDL
        onlineDeviceIDs.contains(device.id)
    }

    // MARK: - TXT record helper

    private func txtValue(_ result: NWBrowser.Result, key: String) -> String? {
        if case .bonjour(let txt) = result.metadata {
            return txt[key]
        }
        return nil
    }
}
