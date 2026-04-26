import SwiftUI

@main
struct BetterDropApp: App {
    @StateObject private var store: AppStore = {
        // Publish the singleton before any engine actors can call back into it
        let s = AppStore()
        AppStore.shared = s
        return s
    }()

    var body: some Scene {
        Window("BetterDrop", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 560, minHeight: 400)
                .onAppear { store.startEngine() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 760, height: 520)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MenuBarPopoverView()
                .environmentObject(store)
                .frame(width: 300)
        } label: {
            MenuBarLabel(pendingCount: store.pendingCount)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    let pendingCount: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: pendingCount > 0
                  ? "arrow.up.arrow.down.circle.fill"
                  : "arrow.up.arrow.down.circle")
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
