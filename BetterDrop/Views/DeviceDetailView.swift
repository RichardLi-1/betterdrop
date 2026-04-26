import SwiftUI

struct DeviceDetailView: View {
    @EnvironmentObject var store: AppStore
    let device: Device

    @State private var filter: TransferFilter = .active
    @State private var isDragOver = false

    enum TransferFilter: String, CaseIterable {
        case active = "Active"
        case history = "History"
    }

    private var transfers: [Transfer] {
        let all = store.transfers(for: device.id)
        switch filter {
        case .active:
            return all.filter { !$0.status.isTerminal }
        case .history:
            return all.filter { $0.status.isTerminal }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            deviceHeader
            Divider()
            dropZone
            filterBar
            Divider()
            transferList
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Header

    private var deviceHeader: some View {
        HStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                DeviceAvatar(device: device, size: 48)
                StatusDot(isOnline: device.isOnline)
                    .offset(x: 3, y: 3)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(device.name)
                    .font(.title3.weight(.semibold))
                HStack(spacing: 6) {
                    Image(systemName: device.platform.icon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(device.platform.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.secondary.opacity(0.5))
                    Text(device.isOnline ? "Online" : "Last seen \(device.displayStatus)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Aggregate stats
            HStack(spacing: 18) {
                statPill(
                    label: "Queued",
                    value: "\(store.transfers(for: device.id).filter { $0.status == .queued }.count)",
                    color: .orange
                )
                statPill(
                    label: "Sent",
                    value: "\(store.transfers(for: device.id).filter { $0.status == .completed }.count)",
                    color: .green
                )
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func statPill(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Drop Zone

    private var dropZone: some View {
        DropZoneView(deviceName: device.name, isDragOver: $isDragOver) { files in
            store.enqueue(files: files, to: device.id)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .onDrop(of: [.fileURL], isTargeted: $isDragOver) { providers in
            handleDrop(providers: providers)
        }
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        HStack {
            Picker("Filter", selection: $filter) {
                ForEach(TransferFilter.allCases, id: \.self) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)

            Spacer()

            if filter == .active && !transfers.isEmpty {
                Button {
                    for t in transfers where t.status == .queued {
                        store.cancelTransfer(t.id)
                    }
                } label: {
                    Text("Cancel All")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    // MARK: - Transfer list

    @ViewBuilder
    private var transferList: some View {
        if transfers.isEmpty {
            emptyTransferState
        } else {
            List {
                ForEach(transfers) { transfer in
                    TransferRowView(transfer: transfer, device: device)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private var emptyTransferState: some View {
        VStack(spacing: 10) {
            Image(systemName: filter == .active ? "tray" : "clock.arrow.circlepath")
                .font(.system(size: 36))
                .foregroundStyle(.secondary.opacity(0.5))
            Text(filter == .active
                 ? "No queued transfers"
                 : "No transfer history")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var files: [TransferFile] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                defer { group.leave() }
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attrs?[.size] as? Int64) ?? 0
                files.append(TransferFile(id: UUID(), name: url.lastPathComponent, size: size, uti: url.pathExtension, localURL: url))
            }
        }
        group.notify(queue: .main) {
            if !files.isEmpty { store.enqueue(files: files, to: device.id) }
        }
        return true
    }
}
