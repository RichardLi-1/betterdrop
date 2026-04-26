import SwiftUI

// MARK: - Status dot

struct StatusDot: View {
    let isOnline: Bool
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(isOnline ? Color.green : Color.secondary.opacity(0.35))
            .frame(width: size, height: size)
            .overlay(
                // Pulse ring for online
                Circle()
                    .stroke(Color.green.opacity(0.3), lineWidth: 1.5)
                    .frame(width: size + 3, height: size + 3)
                    .opacity(isOnline ? 1 : 0)
            )
    }
}

// MARK: - Device avatar (icon inside tinted circle)

struct DeviceAvatar: View {
    let device: Device
    var size: CGFloat = 38

    var body: some View {
        ZStack {
            Circle()
                .fill(device.avatarColor.color.opacity(0.15))
                .frame(width: size, height: size)
            Image(systemName: device.platform.icon)
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(device.avatarColor.color)
        }
    }
}

// MARK: - Drop zone (standalone, used in DeviceDetailView)

struct DropZoneView: View {
    let deviceName: String
    @Binding var isDragOver: Bool
    let onDrop: ([TransferFile]) -> Void

    var body: some View {
        HStack {
            Image(systemName: isDragOver ? "arrow.down.circle.fill" : "plus.circle.dotted")
                .font(.system(size: isDragOver ? 22 : 18))
                .foregroundStyle(isDragOver ? Color.accentColor : Color.secondary.opacity(0.4))
                .symbolRenderingMode(.hierarchical)
                .animation(.spring(response: 0.2), value: isDragOver)

            Text(isDragOver ? "Release to send" : "Drop files to send to \(deviceName)")
                .font(.system(size: 12))
                .foregroundStyle(isDragOver ? Color.accentColor : Color.secondary.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 46)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isDragOver
                      ? Color.accentColor.opacity(0.07)
                      : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isDragOver ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.15),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
        )
        .animation(.easeInOut(duration: 0.15), value: isDragOver)
    }
}
