import Foundation
import Network

// Progress reported back during a transfer
struct TransportProgress {
    let bytesTransferred: Int64
    let totalBytes: Int64
    var fraction: Double { totalBytes > 0 ? Double(bytesTransferred) / Double(totalBytes) : 0 }
}

enum TransportError: Error, LocalizedError {
    case deviceUnreachable
    case connectionRejected
    case transferInterrupted(String)
    case fileReadFailed(URL)
    case encryptionFailed

    var errorDescription: String? {
        switch self {
        case .deviceUnreachable:         return "Device is not reachable"
        case .connectionRejected:        return "Connection was rejected by the device"
        case .transferInterrupted(let r): return "Transfer interrupted: \(r)"
        case .fileReadFailed(let url):   return "Could not read file: \(url.lastPathComponent)"
        case .encryptionFailed:          return "Encryption failed"
        }
    }
}

// A transport handles the actual bytes-over-wire work for one transfer.
// TransportProtocol implementations are stateless — create a new one per transfer.
protocol FileTransport {
    // Human-readable name for logging
    var name: String { get }

    // Whether this transport can currently reach the given device
    func canReach(_ device: Device) async -> Bool

    // Send files; call progressHandler on the main actor as data flows.
    // Throws TransportError on failure.
    func send(
        transfer: Transfer,
        to device: Device,
        progressHandler: @escaping @MainActor (TransportProgress) -> Void
    ) async throws
}

// Ordered list of transports to try for a given device.
// The first one that reports canReach wins.
struct TransportPipeline {
    private let transports: [FileTransport]

    init(transports: [FileTransport]) {
        self.transports = transports
    }

    func bestTransport(for device: Device) async -> FileTransport? {
        for transport in transports {
            if await transport.canReach(device) { return transport }
        }
        return nil
    }

    static func `default`(relayURL: URL) -> TransportPipeline {
        TransportPipeline(transports: [
            AWDLTransport(),
            TCPDirectTransport(),
            RelayTransport(serverURL: relayURL),
        ])
    }
}
