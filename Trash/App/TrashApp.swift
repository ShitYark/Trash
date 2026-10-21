import SwiftUI

@main
struct TrashApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 560)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .defaultSize(width: 1280, height: 860)
        .windowToolbarStyle(.unified)
    }
}
