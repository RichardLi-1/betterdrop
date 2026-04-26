import SwiftUI

/// Compact popover from the menu bar icon.
/// Same card-based drop targets, just smaller.
struct MenuBarPopoverView: View {
    @EnvironmentObject var store: AppStore
    @State private var dragTarget: UUID?

    private var sortedDevices: [Device] {
        store.devices.sorted {
            if $0.isOnline != $1.isOnline { return $0.isOnline }
            return $0.lastSeen > $1.lastSeen
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("BetterDrop")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                Spacer()
                if store.pendingCount > 0 {
                    Text("\(store.pendingCount) pending")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider().padding(.horizontal, 8)

            // Device list
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(sortedDevices) { device in
                        MiniDeviceRow(
                            device: device,
                            pendingCount: store.transfers(for: device.id)
                                .filter { !$0.status.isTerminal }.count,
                            isDropTarget: dragTarget == device.id
                        )
                        .onDrop(of: [.fileURL],
                                isTargeted: Binding(
                                    get: { dragTarget == device.id },
                                    set: { dragTarget = $0 ? device.id : nil }
                                ),
                                perform: { providers in handleDrop(providers, onto: device) })
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 300)

            Divider().padding(.horizontal, 8)

            // Footer
            HStack {
                Button("Open") {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first { $0.identifier?.rawValue == "main" }?.makeKeyAndOrderFront(nil)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

                Spacer()

                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
        }
        .frame(width: 300)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func handleDrop(_ providers: [NSItemProvider], onto device: Device) -> Bool {
        var files: [TransferFile] = []
        let group = DispatchGroup()
        for p in providers {
            group.enter()
            p.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                defer { group.leave() }
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                files.append(TransferFile(id: UUID(), name: url.lastPathComponent, size: size, uti: url.pathExtension, localURL: url))
            }
        }
        group.notify(queue: .main) {
            if !files.isEmpty { store.enqueue(files: files, to: device.id) }
        }
        return true
    }
}

struct MiniDeviceRow: View {
    let device: Device
    let pendingCount: Int
    let isDropTarget: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Icon
            ZStack {
                Circle()
                    .fill(device.avatarColor.color.opacity(isDropTarget ? 0.2 : 0.1))
                    .frame(width: 34, height: 34)
                Image(systemName: isDropTarget ? "arrow.down" : device.platform.icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isDropTarget ? Color.accentColor : device.avatarColor.color)
                    .contentTransition(.symbolEffect(.replace))
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 3) {
                    StatusDot(isOnline: device.isOnline, size: 6)
                    Text(device.isOnline ? "Online" : device.displayStatus)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if pendingCount > 0 {
                Text("\(pendingCount)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15))
                    .foregroundStyle(.orange)
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isDropTarget
                      ? Color.accentColor.opacity(0.08)
                      : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isDropTarget ? Color.accentColor.opacity(0.4) : .clear, lineWidth: 1.5)
        )
        .animation(.spring(response: 0.2), value: isDropTarget)
    }
}
