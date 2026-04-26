import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: AppStore
    @State private var queueDevice: Device?
    @State private var globalDragOver = false

    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 14)
    ]

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                topBar
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        deviceGrid
                    }
                    .padding(24)
                }
            }
        }
        .sheet(item: $queueDevice) { device in
            QueueSheetView(device: device)
                .environmentObject(store)
        }
        .frame(minWidth: 560, minHeight: 400)
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("BetterDrop")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text(store.pendingCount > 0
                     ? "\(store.pendingCount) transfer\(store.pendingCount == 1 ? "" : "s") pending"
                     : "Drop files onto a device")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !store.activeTransfers.isEmpty {
                activePill
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 10)
    }

    private var activePill: some View {
        HStack(spacing: 6) {
            ProgressView()
                .scaleEffect(0.65)
                .frame(width: 12, height: 12)
            Text("Sending…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
    }

    // MARK: - Device grid

    private var deviceGrid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
            ForEach(sortedDevices) { device in
                DeviceCardView(device: device) {
                    queueDevice = device
                }
                .environmentObject(store)
            }
        }
    }

    private var sortedDevices: [Device] {
        store.devices.sorted { a, b in
            if a.isOnline != b.isOnline { return a.isOnline }
            return a.lastSeen > b.lastSeen
        }
    }
}
