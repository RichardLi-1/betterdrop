import Foundation
import SwiftUI
import Combine

@MainActor
final class AppStore: ObservableObject {
    @Published var devices: [Device] = []
    @Published var transfers: [Transfer] = []
    @Published var selectedDeviceID: UUID?

    // Derived
    var pendingCount: Int { transfers.filter { $0.status == .queued || $0.status == .sending }.count }
    var activeTransfers: [Transfer] { transfers.filter { $0.status == .sending } }

    func transfers(for deviceID: UUID) -> [Transfer] {
        transfers
            .filter { $0.targetDeviceID == deviceID }
            .sorted { $0.queuedAt > $1.queuedAt }
    }

    func device(for id: UUID) -> Device? {
        devices.first { $0.id == id }
    }

    func enqueue(files: [TransferFile], to deviceID: UUID) {
        let transfer = Transfer.queued(files: files, to: deviceID)
        transfers.insert(transfer, at: 0)
        if let idx = devices.firstIndex(where: { $0.id == deviceID }),
           devices[idx].isOnline {
            startSending(transferID: transfer.id)
        }
    }

    func cancelTransfer(_ id: UUID) {
        guard let idx = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[idx].status = .cancelled
    }

    func retryTransfer(_ id: UUID) {
        guard let idx = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[idx].status = .queued
        transfers[idx].errorMessage = nil
        transfers[idx].retryCount += 1
        if let deviceIdx = devices.firstIndex(where: { $0.id == transfers[idx].targetDeviceID }),
           devices[deviceIdx].isOnline {
            startSending(transferID: id)
        }
    }

    // MARK: - Preview / simulation

    private func startSending(transferID: UUID) {
        guard let idx = transfers.firstIndex(where: { $0.id == transferID }) else { return }
        transfers[idx].status = .sending
        transfers[idx].startedAt = Date()
        simulateProgress(transferID: transferID)
    }

    private func simulateProgress(transferID: UUID) {
        Task {
            var p = 0.0
            while p < 1.0 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                p = min(p + Double.random(in: 0.02...0.08), 1.0)
                guard let idx = self.transfers.firstIndex(where: { $0.id == transferID }) else { return }
                self.transfers[idx].progress = p
            }
            guard let idx = self.transfers.firstIndex(where: { $0.id == transferID }) else { return }
            self.transfers[idx].status = .completed
            self.transfers[idx].completedAt = Date()
        }
    }

    // MARK: - Preview data

    static func preview() -> AppStore {
        let store = AppStore()
        let colors = CodableColor.presets
        store.devices = [
            Device(id: UUID(), name: "Richard's iPhone",  platform: .iOS,     lastSeen: Date(), isOnline: true,  avatarColor: colors[0], isTrusted: true),
            Device(id: UUID(), name: "Richard's iPad",    platform: .iPadOS,  lastSeen: Date().addingTimeInterval(-120), isOnline: false, avatarColor: colors[1], isTrusted: true),
            Device(id: UUID(), name: "Work MacBook Pro",  platform: .macOS,   lastSeen: Date().addingTimeInterval(-3600), isOnline: false, avatarColor: colors[2], isTrusted: true),
            Device(id: UUID(), name: "Samsung S24",       platform: .android, lastSeen: Date().addingTimeInterval(-86400), isOnline: false, avatarColor: colors[3], isTrusted: false),
            Device(id: UUID(), name: "Windows Desktop",   platform: .windows, lastSeen: Date().addingTimeInterval(-7200), isOnline: false, avatarColor: colors[4], isTrusted: false),
        ]
        let d0 = store.devices[0].id
        let d1 = store.devices[1].id
        let d2 = store.devices[2].id
        store.transfers = [
            Transfer(id: UUID(), targetDeviceID: d0, files: [
                TransferFile(id: UUID(), name: "Vacation.jpg", size: 4_200_000, uti: "public.image", localURL: URL(fileURLWithPath: "/tmp/Vacation.jpg")),
            ], status: .sending, queuedAt: Date().addingTimeInterval(-30), startedAt: Date().addingTimeInterval(-10), completedAt: nil, progress: 0.62, errorMessage: nil, retryCount: 0),
            Transfer(id: UUID(), targetDeviceID: d1, files: [
                TransferFile(id: UUID(), name: "Report.pdf", size: 1_100_000, uti: "com.adobe.pdf", localURL: URL(fileURLWithPath: "/tmp/Report.pdf")),
                TransferFile(id: UUID(), name: "Slides.key", size: 8_300_000, uti: "com.apple.keynote", localURL: URL(fileURLWithPath: "/tmp/Slides.key")),
            ], status: .queued, queuedAt: Date().addingTimeInterval(-90), startedAt: nil, completedAt: nil, progress: 0, errorMessage: nil, retryCount: 0),
            Transfer(id: UUID(), targetDeviceID: d2, files: [
                TransferFile(id: UUID(), name: "Project.zip", size: 52_000_000, uti: "public.zip-archive", localURL: URL(fileURLWithPath: "/tmp/Project.zip")),
            ], status: .queued, queuedAt: Date().addingTimeInterval(-3700), startedAt: nil, completedAt: nil, progress: 0, errorMessage: nil, retryCount: 0),
            Transfer(id: UUID(), targetDeviceID: d0, files: [
                TransferFile(id: UUID(), name: "Screenshot.png", size: 540_000, uti: "public.image", localURL: URL(fileURLWithPath: "/tmp/Screenshot.png")),
            ], status: .completed, queuedAt: Date().addingTimeInterval(-600), startedAt: Date().addingTimeInterval(-580), completedAt: Date().addingTimeInterval(-540), progress: 1, errorMessage: nil, retryCount: 0),
            Transfer(id: UUID(), targetDeviceID: d2, files: [
                TransferFile(id: UUID(), name: "Video.mov", size: 210_000_000, uti: "public.movie", localURL: URL(fileURLWithPath: "/tmp/Video.mov")),
            ], status: .failed, queuedAt: Date().addingTimeInterval(-7000), startedAt: Date().addingTimeInterval(-6800), completedAt: nil, progress: 0.23, errorMessage: "Connection timed out", retryCount: 1),
        ]
        return store
    }
}
