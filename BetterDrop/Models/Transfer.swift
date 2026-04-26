import Foundation

enum TransferStatus: String, Codable {
    case queued       // waiting for device to come online
    case sending      // actively transferring
    case completed    // done
    case failed       // error — can retry
    case cancelled

    var label: String {
        switch self {
        case .queued:    return "Queued"
        case .sending:   return "Sending"
        case .completed: return "Sent"
        case .failed:    return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    var isTerminal: Bool {
        self == .completed || self == .cancelled
    }
}

struct TransferFile: Identifiable, Codable, Hashable {
    let id: UUID
    let name: String
    let size: Int64       // bytes
    let uti: String       // uniform type identifier
    let localURL: URL

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var sfSymbol: String {
        if uti.hasPrefix("public.image") { return "photo" }
        if uti.hasPrefix("public.movie")  { return "film" }
        if uti.hasPrefix("public.audio")  { return "music.note" }
        if uti.contains("pdf")            { return "doc.richtext" }
        if uti.contains("zip") || uti.contains("archive") { return "archivebox" }
        if uti.hasPrefix("public.folder") { return "folder" }
        return "doc"
    }
}

struct Transfer: Identifiable, Codable {
    let id: UUID
    let targetDeviceID: UUID
    var files: [TransferFile]
    var status: TransferStatus
    let queuedAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var progress: Double    // 0.0 – 1.0
    var errorMessage: String?
    var retryCount: Int

    var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }

    var formattedTotalSize: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }

    static func queued(files: [TransferFile], to deviceID: UUID) -> Transfer {
        Transfer(
            id: UUID(),
            targetDeviceID: deviceID,
            files: files,
            status: .queued,
            queuedAt: Date(),
            startedAt: nil,
            completedAt: nil,
            progress: 0,
            errorMessage: nil,
            retryCount: 0
        )
    }
}
