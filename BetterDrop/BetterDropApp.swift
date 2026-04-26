import SwiftUI

@main
struct BetterDropApp: App {
    @StateObject private var store = AppStore.preview()
    @State private var menuBarPopoverShown = false

    var body: some Scene {
        // Main queue manager window (opened from menu bar or Dock)
        Window("BetterDrop", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 700, minHeight: 480)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 860, height: 560)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        // Menu bar extra
        MenuBarExtra {
            MenuBarPopoverView()
                .environmentObject(store)
                .frame(width: 320)
        } label: {
            MenuBarLabel(pendingCount: store.pendingCount)
        }
        .menuBarExtraStyle(.window)
    }
}

// The icon + badge in the system menu bar
struct MenuBarLabel: View {
    let pendingCount: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: pendingCount > 0 ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down.circle")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(pendingCount > 0 ? Color.accentColor : .secondary)
            if pendingCount > 0 {
                Text("\(pendingCount)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
    }
}
