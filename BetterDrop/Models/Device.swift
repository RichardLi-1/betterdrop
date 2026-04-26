import Foundation
import SwiftUI

enum DevicePlatform: String, Codable, CaseIterable {
    case macOS, iOS, iPadOS, windows, android, unknown

    var icon: String {
        switch self {
        case .macOS:    return "laptopcomputer"
        case .iOS:      return "iphone"
        case .iPadOS:   return "ipad"
        case .windows:  return "pc"
        case .android:  return "phone"
        case .unknown:  return "questionmark.circle"
        }
    }

    var label: String { rawValue }
}

struct Device: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var platform: DevicePlatform
    var lastSeen: Date
    var isOnline: Bool
    var avatarColor: CodableColor
    var isTrusted: Bool

    var displayStatus: String {
        if isOnline { return "Online" }
        let interval = Date().timeIntervalSince(lastSeen)
        if interval < 60 { return "Just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }
}

// Codable wrapper for SwiftUI Color
struct CodableColor: Codable, Hashable {
    let red: Double
    let green: Double
    let blue: Double

    var color: Color { Color(red: red, green: green, blue: blue) }

    static let presets: [CodableColor] = [
        .init(red: 0.35, green: 0.53, blue: 0.94),
        .init(red: 0.94, green: 0.45, blue: 0.35),
        .init(red: 0.35, green: 0.80, blue: 0.55),
        .init(red: 0.85, green: 0.60, blue: 0.20),
        .init(red: 0.65, green: 0.40, blue: 0.90),
        .init(red: 0.25, green: 0.75, blue: 0.85),
    ]
}
