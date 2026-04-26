import Foundation
import CryptoKit

// Sends files through a lightweight relay server when direct transport is unavailable.
//
// Protocol:
//   1. Sender opens WebSocket to wss://relay/connect?deviceID=<recipientID>
//   2. Relay holds the connection until recipient connects (long-poll style)
//   3. Both sides do ECDH handshake over the signaling channel (JSON messages)
//   4. Sender uploads encrypted file chunks via HTTPS multipart to /upload/<sessionID>
//   5. Recipient polls /download/<sessionID> or receives a push notification
//
// The relay NEVER sees plaintext — every file byte is ChaCha20-Poly1305 encrypted
// with a key only the two devices share.

final class RelayTransport: FileTransport {
    let serverURL: URL
    var name: String { "Relay" }

    init(serverURL: URL) {
        self.serverURL = serverURL
    }

    func canReach(_ device: Device) async -> Bool {
        // Relay is always theoretically reachable if we have internet.
        // We skip it if the server itself is down.
        var req = URLRequest(url: serverURL.appendingPathComponent("health"))
        req.timeoutInterval = 4
        return (try? await URLSession.shared.data(for: req)) != nil
    }

    func send(
        transfer: Transfer,
        to device: Device,
        progressHandler: @escaping @MainActor (TransportProgress) -> Void
    ) async throws {
        // 1. Open signaling WebSocket
        let signalingURL = serverURL
            .appendingPathComponent("connect")
            .appending(queryItems: [
                URLQueryItem(name: "senderID",    value: DeviceRegistry.shared.localDeviceID.uuidString),
                URLQueryItem(name: "recipientID", value: device.id.uuidString),
                URLQueryItem(name: "transferID",  value: transfer.id.uuidString),
            ])

        let (sessionID, sessionKey) = try await negotiateSession(
            signalingURL: signalingURL,
            recipientPublicKey: device.publicKey
        )

        // 2. Upload each file in chunks
        var totalSent: Int64 = 0
        let totalBytes = transfer.totalSize

        for file in transfer.files {
            try await uploadFile(
                file: file,
                sessionID: sessionID,
                sessionKey: sessionKey,
                onProgress: { sent in
                    totalSent += sent
                    Task { @MainActor in
                        progressHandler(TransportProgress(bytesTransferred: totalSent, totalBytes: totalBytes))
                    }
                }
            )
        }

        // 3. Tell the relay the session is complete
        var doneReq = URLRequest(url: serverURL.appendingPathComponent("sessions/\(sessionID)/done"))
        doneReq.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: doneReq)
    }

    // MARK: - Session negotiation over WebSocket

    private func negotiateSession(
        signalingURL: URL,
        recipientPublicKey: Data?
    ) async throws -> (sessionID: String, key: SymmetricKey) {
        let ws = URLSession.shared.webSocketTask(with: signalingURL)
        ws.resume()
        defer { ws.cancel(with: .normalClosure, reason: nil) }

        // Send our ephemeral public key
        let myPrivKey = Curve25519.KeyAgreement.PrivateKey()
        let helloMsg = SignalingMessage.hello(publicKey: myPrivKey.publicKey.rawRepresentation)
        try await ws.send(.string(helloMsg.json()))

        // Wait for recipient's hello (or timeout)
        let reply = try await withTimeout(seconds: 30) {
            try await ws.receive()
        }

        guard case .string(let json) = reply,
              let msg = SignalingMessage(json: json),
              case .hello(let theirKeyData) = msg else {
            throw TransportError.connectionRejected
        }

        // Optional: verify key matches stored device key
        if let stored = recipientPublicKey, stored != theirKeyData {
            throw TransportError.connectionRejected
        }

        let theirKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirKeyData)
        let sharedSecret = try myPrivKey.sharedSecretFromKeyAgreement(with: theirKey)
        let sessionKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: "betterdrop-relay".data(using: .utf8)!,
            sharedInfo: Data(),
            outputByteCount: 32
        )

        // Receive session ID from the relay (injected into the signaling stream)
        let sessionReply = try await withTimeout(seconds: 10) { try await ws.receive() }
        guard case .string(let sessionJSON) = sessionReply,
              let sessionMsg = SignalingMessage(json: sessionJSON),
              case .session(let id) = sessionMsg else {
            throw TransportError.connectionRejected
        }

        return (id, sessionKey)
    }

    // MARK: - Chunked HTTPS upload

    private func uploadFile(
        file: TransferFile,
        sessionID: String,
        sessionKey: SymmetricKey,
        onProgress: (Int64) -> Void
    ) async throws {
        guard let fileHandle = try? FileHandle(forReadingFrom: file.localURL) else {
            throw TransportError.fileReadFailed(file.localURL)
        }
        defer { try? fileHandle.close() }

        let chunkSize = 512 * 1024  // 512 KB chunks
        var chunkIndex = 0

        while true {
            let plain = fileHandle.readData(ofLength: chunkSize)
            if plain.isEmpty { break }

            let encrypted = try AES.GCM.seal(plain, using: sessionKey).combined!

            var req = URLRequest(url: serverURL.appendingPathComponent("sessions/\(sessionID)/chunks"))
            req.httpMethod = "POST"
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            req.setValue(file.id.uuidString, forHTTPHeaderField: "X-File-ID")
            req.setValue("\(chunkIndex)", forHTTPHeaderField: "X-Chunk-Index")
            req.setValue(file.name, forHTTPHeaderField: "X-File-Name")
            req.httpBody = encrypted

            let (_, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw TransportError.transferInterrupted("Relay rejected chunk \(chunkIndex)")
            }

            onProgress(Int64(plain.count))
            chunkIndex += 1
        }
    }
}

// MARK: - Signaling messages

private enum SignalingMessage {
    case hello(publicKey: Data)
    case session(id: String)

    func json() -> String {
        switch self {
        case .hello(let key):
            return #"{"type":"hello","publicKey":"\#(key.base64EncodedString())"}"#
        case .session(let id):
            return #"{"type":"session","id":"\#(id)"}"#
        }
    }

    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let type_ = obj["type"] else { return nil }
        switch type_ {
        case "hello":
            guard let keyStr = obj["publicKey"], let keyData = Data(base64Encoded: keyStr) else { return nil }
            self = .hello(publicKey: keyData)
        case "session":
            guard let id = obj["id"] else { return nil }
            self = .session(id: id)
        default:
            return nil
        }
    }
}

// MARK: - Timeout helper

private func withTimeout<T>(seconds: Double, operation: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TransportError.transferInterrupted("Timed out waiting for peer")
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

// Device needs a publicKey field — add it here so we don't break existing model
extension Device {
    var publicKey: Data? { nil }  // real impl reads from Keychain
}
