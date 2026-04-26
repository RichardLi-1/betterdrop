import XCTest
@testable import BetterDropEngine

@MainActor
final class TransferQueueTests: XCTestCase {

    // New transfers added while the target device is offline should land in .queued state.
    func testEnqueueToOfflineDeviceStaysQueued() {
        let store = AppStore()
        let device = makeDevice(isOnline: false)
        store.devices = [device]

        let files = [makeFile(name: "photo.jpg", size: 1024)]
        store.enqueue(files: files, to: device.id)

        XCTAssertEqual(store.transfers.count, 1)
        XCTAssertEqual(store.transfers[0].status, .queued)
        XCTAssertEqual(store.pendingCount, 1)
    }

    // Cancelling a queued transfer sets it to .cancelled and removes it from pending count.
    func testCancelReducesPendingCount() {
        let store = AppStore()
        let device = makeDevice(isOnline: false)
        store.devices = [device]
        store.enqueue(files: [makeFile(name: "doc.pdf", size: 512)], to: device.id)

        let id = store.transfers[0].id
        store.cancelTransfer(id)

        XCTAssertEqual(store.transfers[0].status, .cancelled)
        XCTAssertEqual(store.pendingCount, 0)
    }

    // Retrying a failed transfer resets status to .queued and increments retryCount.
    func testRetryResetsToQueued() {
        let store = AppStore()
        let device = makeDevice(isOnline: false)
        store.devices = [device]
        store.enqueue(files: [makeFile(name: "video.mov", size: 1_000_000)], to: device.id)

        let id = store.transfers[0].id
        store.markFailed(transferID: id, error: "timeout")
        XCTAssertEqual(store.transfers[0].status, .failed)
        XCTAssertEqual(store.transfers[0].retryCount, 0)

        store.retryTransfer(id)
        XCTAssertEqual(store.transfers[0].status, .queued)
        XCTAssertEqual(store.transfers[0].retryCount, 1)
    }

    // transfers(for:) returns only transfers belonging to the specified device.
    func testTransfersForDeviceIsolation() {
        let store = AppStore()
        let a = makeDevice(isOnline: false)
        let b = makeDevice(isOnline: false)
        store.devices = [a, b]

        store.enqueue(files: [makeFile(name: "a.jpg", size: 100)], to: a.id)
        store.enqueue(files: [makeFile(name: "b.jpg", size: 200)], to: b.id)

        XCTAssertEqual(store.transfers(for: a.id).count, 1)
        XCTAssertEqual(store.transfers(for: b.id).count, 1)
        XCTAssertEqual(store.transfers(for: a.id)[0].files[0].name, "a.jpg")
    }

    // Progress updates from the engine propagate to the correct transfer.
    func testProgressUpdate() {
        let store = AppStore()
        let device = makeDevice(isOnline: true)
        store.devices = [device]
        store.enqueue(files: [makeFile(name: "archive.zip", size: 50_000)], to: device.id)

        let id = store.transfers[0].id
        store.beginSending(transferID: id)
        store.updateProgress(transferID: id, progress: 0.5)

        XCTAssertEqual(store.transfers[0].progress, 0.5, accuracy: 0.001)
        XCTAssertEqual(store.transfers[0].status, .sending)
    }

    // markCompleted sets terminal state correctly.
    func testMarkCompleted() {
        let store = AppStore()
        let device = makeDevice(isOnline: true)
        store.devices = [device]
        store.enqueue(files: [makeFile(name: "notes.txt", size: 256)], to: device.id)

        let id = store.transfers[0].id
        store.beginSending(transferID: id)
        store.markCompleted(transferID: id)

        let t = store.transfers[0]
        XCTAssertEqual(t.status, .completed)
        XCTAssertEqual(t.progress, 1.0)
        XCTAssertNotNil(t.completedAt)
        XCTAssertEqual(store.pendingCount, 0)
    }

    // MARK: - Helpers

    private func makeDevice(isOnline: Bool) -> Device {
        Device(
            id: UUID(),
            name: "Test Device",
            platform: .iOS,
            lastSeen: Date(),
            isOnline: isOnline,
            avatarColor: CodableColor(red: 0.3, green: 0.5, blue: 0.9),
            isTrusted: true
        )
    }

    private func makeFile(name: String, size: Int64) -> TransferFile {
        TransferFile(
            id: UUID(),
            name: name,
            size: size,
            uti: "public.item",
            localURL: URL(fileURLWithPath: "/tmp/\(name)")
        )
    }
}
