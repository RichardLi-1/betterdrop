import SwiftUI

struct DeviceListView: View {
    @EnvironmentObject var store: AppStore
    @State private var searchText = ""
    @State private var showAddSheet = false

    private var onlineDevices: [Device] {
        filtered.filter { $0.isOnline }
    }

    private var offlineDevices: [Device] {
        filtered.filter { !$0.isOnline }.sorted { $0.lastSeen > $1.lastSeen }
    }

    private var filtered: [Device] {
        guard !searchText.isEmpty else { return store.devices }
        return store.devices.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List(selection: $store.selectedDeviceID) {
            if !onlineDevices.isEmpty {
                Section("Online") {
                    ForEach(onlineDevices) { device in
                        DeviceRow(device: device)
                            .tag(device.id)
                    }
                }
            }

            Section(onlineDevices.isEmpty ? "Devices" : "Offline") {
                if offlineDevices.isEmpty && onlineDevices.isEmpty {
                    Text("No devices found")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(offlineDevices) { device in
                        DeviceRow(device: device)
                            .tag(device.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search devices")
        .navigationTitle("BetterDrop")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAddSheet = true } label: {
                    Image(systemName: "plus")
                }
                .help("Add Device")
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddDeviceSheet()
                .environmentObject(store)
        }
    }
}

struct DeviceRow: View {
    @EnvironmentObject var store: AppStore
    let device: Device

    private var queueCount: Int {
        store.transfers(for: device.id).filter { !$0.status.isTerminal }.count
    }

    private var activeTransfer: Transfer? {
        store.transfers(for: device.id).first { $0.status == .sending }
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                DeviceAvatar(device: device, size: 34)
                StatusDot(isOnline: device.isOnline)
                    .offset(x: 2, y: 2)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                if let active = activeTransfer {
                    // Show progress bar for active transfer
                    HStack(spacing: 5) {
                        ProgressView(value: active.progress)
                            .progressViewStyle(.linear)
                            .frame(width: 60)
                            .tint(.accentColor)
                        Text(active.files.first?.name ?? "")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text(device.isOnline ? device.platform.label : device.displayStatus)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if queueCount > 0 {
                QueueBadge(count: queueCount, isActive: activeTransfer != nil)
            }
        }
        .padding(.vertical, 2)
    }
}

struct QueueBadge: View {
    let count: Int
    let isActive: Bool

    var body: some View {
        Text("\(count)")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .monospacedDigit()
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(isActive ? Color.accentColor : Color.secondary.opacity(0.2))
            .foregroundStyle(isActive ? .white : .secondary)
            .clipShape(Capsule())
    }
}

struct AddDeviceSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Text("Add Device")
                .font(.title2.weight(.semibold))
            Text("Nearby BetterDrop peers will appear automatically.\nTo add a device manually, have them open BetterDrop and enable discovery.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(32)
        .frame(width: 380)
    }
}
