import SwiftUI

/// Full-screen sheet showing a device's queue.
/// Opened by tapping a device card.
struct QueueSheetView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    let device: Device

    @State private var filter: QueueFilter = .active

    enum QueueFilter: String, CaseIterable {
        case active = "Pending"
        case history = "History"
    }

    private var transfers: [Transfer] {
        store.transfers(for: device.id).filter { t in
            filter == .active ? !t.status.isTerminal : t.status.isTerminal
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider()
            filterBar
            if transfers.isEmpty {
                emptyState
            } else {
                transferList
            }
        }
        .frame(width: 480, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var sheetHeader: some View {
        HStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(device.avatarColor.color.opacity(0.15))
                    .frame(width: 46, height: 46)
                Image(systemName: device.platform.icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(device.avatarColor.color)
                StatusDot(isOnline: device.isOnline)
                    .offset(x: 3, y: 3)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.system(size: 16, weight: .bold))
                HStack(spacing: 6) {
                    Text(device.platform.label)
                    Text("·")
                    Text(device.isOnline ? "Online now" : "Last seen \(device.displayStatus)")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        HStack {
            Picker("", selection: $filter) {
                ForEach(QueueFilter.allCases, id: \.self) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)

            Spacer()

            if filter == .active && !transfers.isEmpty {
                Button("Cancel all") {
                    for t in transfers where t.status == .queued {
                        store.cancelTransfer(t.id)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
    }

    // MARK: - List

    private var transferList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(transfers) { transfer in
                    TransferRowView(transfer: transfer, device: device)
                        .environmentObject(store)
                }
            }
            .padding(16)
        }
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: filter == .active ? "tray" : "clock.arrow.circlepath")
                .font(.system(size: 40))
                .foregroundStyle(.secondary.opacity(0.4))
            Text(filter == .active ? "Nothing queued" : "No history yet")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
            if filter == .active {
                Text("Drop files onto the device card to queue a transfer.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 240)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
