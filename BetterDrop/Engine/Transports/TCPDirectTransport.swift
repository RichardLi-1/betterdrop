import Foundation
import Network
import CryptoKit

// Sends files over a direct TLS 1.3 connection on the local network.
// Used when both devices are on the same LAN but AWDL isn't available.
//
// Wire protocol (per file):
//   HEADER  [8B magic][16B transferID][16B fileID][8B totalSize][2B nameLen][nameLen nameUTF8]
//   CHUNKs  [4B chunkIndex][4B chunkCount][4B dataLen][dataLen encryptedBytes]
//   DONE    [8B magic_done]
//
// Each chunk is encrypted with ChaCha20-Poly1305 using a session key derived
// from an ECDH handshake at connection time.

final class TCPDirectTransport: FileTransport {
    static let serviceType  = "_betterdrop._tcp"
    static let port: NWEndpoint.Port = 52_840
    static let chunkSize    = 256 * 1024   // 256 KB

    private static let magicHeader: [UInt8] = [0x42, 0x44, 0x52, 0x50, 0x01, 0x00, 0x00, 0x00]
    private static let magicDone:   [UInt8] = [0x42, 0x44, 0x52, 0x50, 0xFF, 0xFF, 0xFF, 0xFF]

    var name: String { "TCP/LAN" }

    // DeviceRegistry populates this: deviceID → resolved NWEndpoint
    static var resolvedEndpoints: [UUID: NWEndpoint] = [:]

    func canReach(_ device: Device) async -> Bool {
        Self.resolvedEndpoints[device.id] != nil
    }

    func send(
        transfer: Transfer,
        to device: Device,
        progressHandler: @escaping @MainActor (TransportProgress) -> Void
    ) async throws {
        guard let endpoint = Self.resolvedEndpoints[device.id] else {
            throw TransportError.deviceUnreachable
        }

        let params = NWParameters.tls
        params.allowLocalEndpointReuse = true

        let conn = NWConnection(to: endpoint, using: params)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.stateUpdateHandler = nil
                    cont.resume()
                case .failed(let err):
                    conn.stateUpdateHandler = nil
                    cont.resume(throwing: TransportError.connectionRejected)
                    _ = err
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }

        defer { conn.cancel() }

        // ECDH handshake — exchange ephemeral Curve25519 public keys
        let sessionKey = try await performHandshake(conn: conn, remotePublicKey: device.publicKey)

        var totalSent: Int64 = 0
        let totalBytes = transfer.totalSize

        for file in transfer.files {
            try await sendFile(
                file: file,
                transferID: transfer.id,
                conn: conn,
                sessionKey: sessionKey,
                onChunk: { sent in
                    totalSent += sent
                    Task { @MainActor in
                        progressHandler(TransportProgress(bytesTransferred: totalSent, totalBytes: totalBytes))
                    }
                }
            )
        }

        // Signal completion
        try await sendRaw(conn: conn, data: Data(Self.magicDone))
    }

    // MARK: - Handshake

    private func performHandshake(conn: NWConnection, remotePublicKey: Data?) async throws -> SymmetricKey {
        let myKey = Curve25519.KeyAgreement.PrivateKey()
        let myPublicKeyData = myKey.publicKey.rawRepresentation

        // Send our public key (32 bytes)
        try await sendRaw(conn: conn, data: myPublicKeyData)

        // Receive theirs (32 bytes)
        let theirKeyData = try await receiveExact(conn: conn, count: 32)
        let theirKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirKeyData)

        // Optional: verify against stored public key for this device
        if let stored = remotePublicKey,
           stored != theirKeyData {
            throw TransportError.connectionRejected // key mismatch — possible MITM
        }

        let sharedSecret = try myKey.sharedSecretFromKeyAgreement(with: theirKey)
        return sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: "betterdrop-session".data(using: .utf8)!,
            sharedInfo: Data(),
            outputByteCount: 32
        )
    }

    // MARK: - File send

    private func sendFile(
        file: TransferFile,
        transferID: UUID,
        conn: NWConnection,
        sessionKey: SymmetricKey,
        onChunk: (Int64) -> Void
    ) async throws {
        guard let fileHandle = try? FileHandle(forReadingFrom: file.localURL) else {
            throw TransportError.fileReadFailed(file.localURL)
        }
        defer { try? fileHandle.close() }

        let nameData = file.name.data(using: .utf8) ?? Data()
        let chunkCount = UInt32((file.size + Int64(Self.chunkSize) - 1) / Int64(Self.chunkSize))

        // Header
        var header = Data(Self.magicHeader)
        header.append(transferID.uuidData)
        header.append(file.id.uuidData)
        withUnsafeBytes(of: file.size.bigEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(nameData.count).bigEndian) { header.append(contentsOf: $0) }
        header.append(nameData)
        try await sendRaw(conn: conn, data: header)

        // Chunks
        var chunkIndex: UInt32 = 0
        while true {
            let chunk = fileHandle.readData(ofLength: Self.chunkSize)
            if chunk.isEmpty { break }

            let encrypted = try AES.GCM.seal(chunk, using: sessionKey).combined!

            var frame = Data()
            withUnsafeBytes(of: chunkIndex.bigEndian)  { frame.append(contentsOf: $0) }
            withUnsafeBytes(of: chunkCount.bigEndian)  { frame.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt32(encrypted.count).bigEndian) { frame.append(contentsOf: $0) }
            frame.append(encrypted)

            try await sendRaw(conn: conn, data: frame)

            // Wait for ACK (1 byte: 0x01 = ok, 0x00 = retry)
            let ack = try await receiveExact(conn: conn, count: 1)
            if ack.first == 0x00 { throw TransportError.transferInterrupted("Chunk \(chunkIndex) rejected by receiver") }

            onChunk(Int64(chunk.count))
            chunkIndex += 1
        }
    }

    // MARK: - NWConnection helpers

    private func sendRaw(conn: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: TransportError.transferInterrupted(error.localizedDescription)) }
                else { cont.resume() }
            })
        }
    }

    private func receiveExact(conn: NWConnection, count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, isComplete, error in
                if let error {
                    cont.resume(throwing: TransportError.transferInterrupted(error.localizedDescription))
                } else if let data, data.count == count {
                    cont.resume(returning: data)
                } else {
                    cont.resume(throwing: TransportError.transferInterrupted("Short read"))
                }
            }
        }
    }
}

// MARK: - UUID → raw bytes helper

private extension UUID {
    var uuidData: Data {
        withUnsafeBytes(of: uuid) { Data($0) }
    }
}

// Stub for the receiver side (runs on iOS/macOS companion)
final class TCPDirectReceiver {
    private var listener: NWListener?

    func start(privateKey: Curve25519.KeyAgreement.PrivateKey) throws {
        let params = NWParameters.tls
        listener = try NWListener(using: params, on: TCPDirectTransport.port)
        listener?.service = NWListener.Service(type: TCPDirectTransport.serviceType)
        listener?.newConnectionHandler = { conn in
            conn.start(queue: .global(qos: .userInitiated))
            // TODO: handle incoming transfer (mirror of TCPDirectTransport.send)
        }
        listener?.start(queue: .global(qos: .userInitiated))
    }

    func stop() { listener?.cancel() }
}
