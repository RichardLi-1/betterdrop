import Foundation

// The brain of offline queuing.
//
// Responsibilities:
//   - On .deviceOnline notification: immediately drain the queue for that device
//   - On a periodic heartbeat: retry failed transfers that are due for retry
//   - Coordinate with the TransportPipeline to pick the right transport
//   - Report progress back to AppStore on the main actor
//
// Runs as a Swift actor to serialize queue mutations without locks.

actor QueueProcessor {
    static let shared = QueueProcessor()

    private let relayURL = URL(string: "wss://relay.betterdrop.app")!
    private var pipeline: TransportPipeline { .default(relayURL: relayURL) }

    // Tracks which transferIDs are currently in-flight so we don't double-send
    private var inFlight: Set<UUID> = []

    private var notificationObserver: Any?
    private var heartbeatTask: Task<Void, Never>?

    // MARK: - Lifecycle

    func start() {
        // Listen for devices coming online
        notificationObserver = NotificationCenter.default.addObserver(
            forName: .deviceOnline,
            object: nil,
            queue: nil
        ) { notification in
            guard let deviceID = notification.object as? UUID else { return }
            Task { await self.drainQueue(for: deviceID) }
        }

        // Heartbeat: re-check failed transfers every 5 minutes
        heartbeatTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
                await retryEligibleTransfers()
            }
        }
    }

    func stop() {
        if let obs = notificationObserver {
            NotificationCenter.default.removeObserver(obs)
            notificationObserver = nil
        }
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    // MARK: - Queue draining

    // Called when a device comes online. Sends all queued transfers for it,
    // oldest first, one at a time (simpler UX than parallel).
    func drainQueue(for deviceID: UUID) async {
        let store = await AppStore.shared
        let device = await store.device(for: deviceID)
        guard let device else { return }

        let queued = await store.transfers(for: deviceID)
            .filter { $0.status == .queued }
            .sorted { $0.queuedAt < $1.queuedAt }

        for transfer in queued {
            guard !inFlight.contains(transfer.id) else { continue }
            await execute(transfer: transfer, device: device, store: store)
        }
    }

    // MARK: - Single transfer execution

    private func execute(transfer: Transfer, device: Device, store: AppStore) async {
        inFlight.insert(transfer.id)
        defer { inFlight.remove(transfer.id) }

        // Choose transport
        guard let transport = await pipeline.bestTransport(for: device) else {
            await markFailed(
                transfer: transfer,
                store: store,
                error: TransportError.deviceUnreachable
            )
            return
        }

        // Mark sending in the UI
        await store.beginSending(transferID: transfer.id)

        do {
            try await transport.send(
                transfer: transfer,
                to: device,
                progressHandler: { progress in
                    Task { @MainActor in
                        await store.updateProgress(
                            transferID: transfer.id,
                            progress: progress.fraction
                        )
                    }
                }
            )

            // Success
            await store.markCompleted(transferID: transfer.id)
            try? await Database.shared.markCompleted(transferID: transfer.id)

        } catch {
            await markFailed(transfer: transfer, store: store, error: error)
        }
    }

    private func markFailed(transfer: Transfer, store: AppStore, error: Error) async {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        await store.markFailed(transferID: transfer.id, error: message)
        try? await Database.shared.markFailed(transferID: transfer.id, error: message)
        scheduleRetry(transfer: transfer)
    }

    // MARK: - Retry policy: exponential backoff, cap 1 hour, give up after 5 attempts

    private var retryDue: [UUID: Date] = [:]

    private func scheduleRetry(transfer: Transfer) {
        guard transfer.retryCount < 5 else { return }
        let delay = min(pow(2.0, Double(transfer.retryCount)) * 30, 3600)  // 30s, 60s, 120s, 240s, 480s
        retryDue[transfer.id] = Date().addingTimeInterval(delay)
    }

    private func retryEligibleTransfers() async {
        let now = Date()
        let due = retryDue.filter { $0.value <= now }.map { $0.key }
        guard !due.isEmpty else { return }

        let store = await AppStore.shared
        for id in due {
            retryDue.removeValue(forKey: id)
            await store.requeueTransfer(id)
            // The next .deviceOnline notification (or next heartbeat) will pick it up
        }
    }
}
