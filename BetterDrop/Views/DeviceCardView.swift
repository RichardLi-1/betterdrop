import SwiftUI

/// The primary UI element — a large tappable/droppable card per device.
/// This IS the drop target. Make it impossible to miss.
struct DeviceCardView: View {
    @EnvironmentObject var store: AppStore
    let device: Device
    let onTap: () -> Void

    @State private var isDragOver = false
    @State private var isHovered = false
    @State private var dropFlash = false  // brief green flash on successful drop

    private var pendingCount: Int {
        store.transfers(for: device.id).filter { !$0.status.isTerminal }.count
    }

    private var activeTransfer: Transfer? {
        store.transfers(for: device.id).first { $0.status == .sending }
    }

    var body: some View {
        Button(action: onTap) {
            cardContent
        }
        .buttonStyle(.plain)
        .onDrop(of: [.fileURL], isTargeted: $isDragOver, perform: handleDrop)
        .onHover { isHovered = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isDragOver)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }

    // MARK: - Card body

    private var cardContent: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 18)

            // Device icon — large and central
            ZStack {
                Circle()
                    .fill(device.avatarColor.color.opacity(isDragOver ? 0.25 : 0.12))
                    .frame(width: 68, height: 68)
                    .scaleEffect(isDragOver ? 1.08 : 1.0)

                if dropFlash {
                    Circle()
                        .fill(Color.green.opacity(0.3))
                        .frame(width: 68, height: 68)
                }

                Image(systemName: isDragOver ? "arrow.down.circle.fill" : device.platform.icon)
                    .font(.system(size: isDragOver ? 30 : 26, weight: .medium))
                    .foregroundStyle(isDragOver ? Color.accentColor : device.avatarColor.color)
                    .contentTransition(.symbolEffect(.replace))
                    .scaleEffect(isDragOver ? 1.1 : 1.0)
            }

            Spacer(minLength: 12)

            // Name + platform
            VStack(spacing: 3) {
                Text(device.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)

                HStack(spacing: 4) {
                    StatusDot(isOnline: device.isOnline)
                    Text(device.isOnline ? "Online" : device.displayStatus)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 14)

            // Queue badge or progress bar
            bottomDetail

            Spacer(minLength: 16)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 190)
        .background(cardBackground)
        .overlay(dropOverlay)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(
            color: isDragOver ? Color.accentColor.opacity(0.2) : .black.opacity(0.06),
            radius: isDragOver ? 14 : 6,
            y: isDragOver ? 4 : 2
        )
    }

    @ViewBuilder
    private var bottomDetail: some View {
        if let transfer = activeTransfer {
            // Active progress indicator
            VStack(spacing: 4) {
                ProgressView(value: transfer.progress)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .padding(.horizontal, 18)
                Text("\(Int(transfer.progress * 100))%")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } else if pendingCount > 0 {
            // Queued badge
            HStack(spacing: 4) {
                Image(systemName: "clock.fill")
                    .font(.system(size: 9))
                Text("\(pendingCount) queued")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.orange.opacity(0.1))
            .clipShape(Capsule())
        } else if !device.isOnline {
            // Offline hint
            Text("Will send when online")
                .font(.system(size: 10))
                .foregroundStyle(.secondary.opacity(0.7))
        } else {
            // Drop hint
            Text("Drop files here")
                .font(.system(size: 10))
                .foregroundStyle(.secondary.opacity(isDragOver ? 0 : 0.5))
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(isDragOver
                  ? Color.accentColor.opacity(0.07)
                  : Color(nsColor: .controlBackgroundColor))
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(
                isDragOver ? Color.accentColor.opacity(0.6) : Color.clear,
                style: StrokeStyle(lineWidth: 2, dash: isDragOver ? [6, 4] : [])
            )
    }

    // MARK: - Drop handler

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
                files.append(TransferFile(
                    id: UUID(), name: url.lastPathComponent,
                    size: size, uti: url.pathExtension, localURL: url
                ))
            }
        }
        group.notify(queue: .main) {
            guard !files.isEmpty else { return }
            store.enqueue(files: files, to: device.id)
            // Brief success flash
            withAnimation(.easeIn(duration: 0.1)) { dropFlash = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation { dropFlash = false }
            }
        }
        return true
    }
}
