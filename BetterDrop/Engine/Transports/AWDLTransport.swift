import Foundation
import AppKit
import Network

// Wraps macOS native AirDrop via NSSharingService.
//
// Trade-off: we get native OS UI + zero extra networking code, but we lose
// byte-level progress. Progress is approximated: 0% → 50% while the OS
// dialog is up, 50% → 100% once the service completes.
//
// AWDL (Apple Wireless Direct Link) only works when both devices are
// physically nearby (Bluetooth + WiFi). The DeviceRegistry detects AWDL
// reachability by attempting an AWDL-interface resolve via NWPathMonitor.

final class AWDLTransport: NSObject, FileTransport, NSSharingServiceDelegate {
    var name: String { "AWDL/AirDrop" }

    // Continuations held across the async boundary so the delegate callbacks
    // can resume them.
    private var doneContinuation: CheckedContinuation<Void, Error>?

    func canReach(_ device: Device) async -> Bool {
        // AirDrop is available if the AWDL interface is up and the device
        // was seen recently via Bonjour on AWDL.
        guard NSSharingService(named: .sendViaAirDrop) != nil else { return false }
        let reachableViaRegistry = await MainActor.run {
            DeviceRegistry.shared.isReachableViaAWDL(device)
        }
        return AWDLReachabilityMonitor.shared.isAWDLUp && reachableViaRegistry
    }

    func send(
        transfer: Transfer,
        to device: Device,
        progressHandler: @escaping @MainActor (TransportProgress) -> Void
    ) async throws {
        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            throw TransportError.deviceUnreachable
        }
        service.delegate = self

        // AirDrop shares URLs
        let urls = transfer.files.map { $0.localURL }
        guard service.canPerform(withItems: urls) else {
            throw TransportError.deviceUnreachable
        }

        // Fake progress 0 → 50% while the share sheet is shown
        Task { @MainActor in
            progressHandler(TransportProgress(bytesTransferred: 0, totalBytes: transfer.totalSize))
        }

        // The share is synchronous from AppKit's perspective; we wrap it in an async
        // continuation so the caller can await it cleanly.
        try await withCheckedThrowingContinuation { [weak self] (cont: CheckedContinuation<Void, Error>) in
            self?.doneContinuation = cont
            Task { @MainActor in
                service.perform(withItems: urls)
                // Announce mid-point once the sheet appears
                progressHandler(TransportProgress(
                    bytesTransferred: transfer.totalSize / 2,
                    totalBytes: transfer.totalSize
                ))
            }
        }
    }

    // MARK: - NSSharingServiceDelegate

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        doneContinuation?.resume()
        doneContinuation = nil
    }

    func sharingService(
        _ sharingService: NSSharingService,
        didFailToShareItems items: [Any],
        error: Error
    ) {
        doneContinuation?.resume(throwing: TransportError.transferInterrupted(error.localizedDescription))
        doneContinuation = nil
    }
}

// Monitors whether the AWDL network interface is active.
// AWDL only comes up when AirDrop or AirPlay is in use; it can stay up
// briefly after, then goes back to sleep.
final class AWDLReachabilityMonitor {
    static let shared = AWDLReachabilityMonitor()
    private(set) var isAWDLUp = false

    private let monitor = NWPathMonitor(requiredInterfaceType: .wifi)

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            // AWDL shows up as an unsatisfied path on the WiFi monitor when
            // the main WiFi isn't available — but the cleaner check is to
            // look for AWDL directly via the interface name via BSD sockets.
            self?.isAWDLUp = path.availableInterfaces.contains { $0.name == "awdl0" }
        }
        monitor.start(queue: .global(qos: .background))
    }
}
