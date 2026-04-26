import SwiftUI

struct TransferRowView: View {
    @EnvironmentObject var store: AppStore
    let transfer: Transfer
    let device: Device

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            fileStackIcon

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    fileNames
                    Spacer()
                    statusBadge
                }
                metaRow
                if transfer.status == .sending {
                    progressBar
                }
                if let err = transfer.errorMessage {
                    errorRow(err)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
        )
        .contextMenu {
            if transfer.status == .queued || transfer.status == .sending {
                Button("Cancel", role: .destructive) { store.cancelTransfer(transfer.id) }
            }
            if transfer.status == .failed {
                Button("Retry") { store.retryTransfer(transfer.id) }
            }
            if transfer.status == .completed {
                Button("Resend") { store.enqueue(files: transfer.files, to: transfer.targetDeviceID) }
            }
            Divider()
            Button("Show in Finder") {
                if let url = transfer.files.first?.localURL {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
    }

    // MARK: - Sub-views

    private var fileStackIcon: some View {
        ZStack {
            if transfer.files.count > 1 {
                // Stacked appearance for multiple files
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: 38, height: 44)
                    .offset(x: 3, y: -3)
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: 38, height: 44)
                    .offset(x: 1.5, y: -1.5)
            }
            RoundedRectangle(cornerRadius: 6)
                .fill(statusColor.opacity(0.12))
                .frame(width: 38, height: 44)
            Image(systemName: transfer.files.first?.sfSymbol ?? "doc")
                .font(.system(size: 18))
                .foregroundStyle(statusColor)
        }
    }

    private var fileNames: some View {
        VStack(alignment: .leading, spacing: 2) {
            if transfer.files.count == 1 {
                Text(transfer.files[0].name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            } else {
                Text("\(transfer.files.count) files")
                    .font(.system(size: 13, weight: .medium))
                Text(transfer.files.prefix(3).map { $0.name }.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var statusBadge: some View {
        Text(transfer.status.label)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(statusColor.opacity(0.12))
            .foregroundStyle(statusColor)
            .clipShape(Capsule())
    }

    private var metaRow: some View {
        HStack(spacing: 8) {
            Text(transfer.formattedTotalSize)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("·").foregroundStyle(.secondary.opacity(0.4))

            Text(relativeDate(transfer.queuedAt))
                .font(.caption)
                .foregroundStyle(.secondary)

            if transfer.retryCount > 0 {
                Text("·").foregroundStyle(.secondary.opacity(0.4))
                Text("Retry \(transfer.retryCount)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Spacer()

            // Action buttons
            HStack(spacing: 6) {
                if transfer.status == .queued {
                    Button { store.cancelTransfer(transfer.id) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel")
                }
                if transfer.status == .failed {
                    Button { store.retryTransfer(transfer.id) } label: {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .help("Retry")
                }
            }
        }
    }

    private var progressBar: some View {
        VStack(alignment: .trailing, spacing: 2) {
            ProgressView(value: transfer.progress)
                .progressViewStyle(.linear)
                .tint(statusColor)
            Text("\(Int(transfer.progress * 100))%  ·  \(ByteCountFormatter.string(fromByteCount: Int64(Double(transfer.totalSize) * transfer.progress), countStyle: .file)) of \(transfer.formattedTotalSize)")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func errorRow(_ message: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
            Text(message)
                .font(.caption)
                .foregroundStyle(.red.opacity(0.8))
        }
    }

    // MARK: - Helpers

    private var statusColor: Color {
        switch transfer.status {
        case .queued:    return .orange
        case .sending:   return .accentColor
        case .completed: return .green
        case .failed:    return .red
        case .cancelled: return .secondary
        }
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
