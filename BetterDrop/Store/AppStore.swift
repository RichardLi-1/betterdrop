import Foundation
import SwiftUI
import Combine

@MainActor
final class AppStore: ObservableObject {
    // Singleton used by engine actors (QueueProcessor) to push state back to the UI.
    // Views use @EnvironmentObject, not this singleton.
    static var shared: AppStore = AppStore()

    @Published var devices: [Device] = []
    @Published var transfers: [Transfer] = []
    @Published var selectedDeviceID: UUID?

    // MARK: - Derived

    var pendingCount: Int { transfers.filter { $0.status == .queued || $0.status == .sending }.count }
    var activeTransfers: [Transfer] { transfers.filter { $0.status == .sending } }

    func transfers(for deviceID: UUID) -> [Transfer] {
        transfers
            .filter { $0.targetDeviceID == deviceID }
            .sorted { $0.queuedAt > $1.queuedAt }
    }

    func device(for id: UUID) -> Device? { devices.first { $0.id == id } }

    // MARK: - Engine startup

    func startEngine() {
        Task {
            // Load persisted state from SQLite
            if let savedDevices = try? await Database.shared.loadDevices() {
                devices = savedDevices
            }
            if let savedTransfers = try? await Database.shared.loadTransfers() {
                // Only restore non-terminal transfers; completed/cancelled are shown in history
                transfers = savedTransfers
            }

            // Merge online state from DeviceRegistry into loaded devices
            for id in DeviceRegistry.shared.onlineDeviceIDs {
                if let idx = devices.firstIndex(where: { $0.id == id }) {
                    devices[idx].isOnline = true
                }
            }

            // Mirror DeviceRegistry discoveries into our device list
            observeRegistry()

            DeviceRegistry.shared.startDiscovery()
            await QueueProcessor.shared.start()

            // Try to send anything that was .queued when we last quit
            for id in DeviceRegistry.shared.onlineDeviceIDs {
                await QueueProcessor.shared.drainQueue(for: id)
            }
        }
    }

    // MARK: - Sync DeviceRegistry → devices array

    private func observeRegistry() {
        NotificationCenter.default.addObserver(forName: .deviceOnline, object: nil, queue: .main) { [weak self] note in
            guard let self, let id = note.object as? UUID else { return }
            if let idx = self.devices.firstIndex(where: { $0.id == id }) {
                self.devices[idx].isOnline = true
                self.devices[idx].lastSeen = Date()
            } else if let device = DeviceRegistry.shared.knownDevices[id] {
                self.devices.append(device)
            }
        }
        NotificationCenter.default.addObserver(forName: .deviceOffline, object: nil, queue: .main) { [weak self] note in
            guard let self, let id = note.object as? UUID else { return }
            if let idx = self.devices.firstIndex(where: { $0.id == id }) {
                self.devices[idx].isOnline = false
            }
        }
    }

    // MARK: - Queue mutations (called by UI)

    func enqueue(files: [TransferFile], to deviceID: UUID) {
        let transfer = Transfer.queued(files: files, to: deviceID)
        transfers.insert(transfer, at: 0)

        Task {
            try? await Database.shared.insertTransfer(transfer)
            // If device is already online, kick the queue immediately
            if devices.first(where: { $0.id == deviceID })?.isOnline == true {
                await QueueProcessor.shared.drainQueue(for: deviceID)
            }
        }
    }

    func cancelTransfer(_ id: UUID) {
        guard let idx = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[idx].status = .cancelled
        Task { try? await Database.shared.updateStatus(.cancelled, for: id) }
    }

    func retryTransfer(_ id: UUID) {
        guard let idx = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[idx].status = .queued
        transfers[idx].errorMessage = nil
        transfers[idx].retryCount += 1
        let deviceID = transfers[idx].targetDeviceID
        Task {
            try? await Database.shared.updateStatus(.queued, for: id)
            if devices.first(where: { $0.id == deviceID })?.isOnline == true {
                await QueueProcessor.shared.drainQueue(for: deviceID)
            }
        }
    }

    // MARK: - Queue mutations (called by QueueProcessor)

    func beginSending(transferID: UUID) {
        guard let idx = transfers.firstIndex(where: { $0.id == transferID }) else { return }
        transfers[idx].status = .sending
        transfers[idx].startedAt = Date()
    }

    func updateProgress(transferID: UUID, progress: Double) {
        guard let idx = transfers.firstIndex(where: { $0.id == transferID }) else { return }
        transfers[idx].progress = progress
    }

    func markCompleted(transferID: UUID) {
        guard let idx = transfers.firstIndex(where: { $0.id == transferID }) else { return }
        transfers[idx].status = .completed
        transfers[idx].completedAt = Date()
        transfers[idx].progress = 1
    }

    func markFailed(transferID: UUID, error: String) {
        guard let idx = transfers.firstIndex(where: { $0.id == transferID }) else { return }
        transfers[idx].status = .failed
        transfers[idx].errorMessage = error
    }

    func requeueTransfer(_ id: UUID) {
        guard let idx = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[idx].status = .queued
        transfers[idx].errorMessage = nil
    }

    // MARK: - Preview

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
        ]
        return store
    }
}
