import SwiftUI

@main
struct BurrowBoltApp: App {
    init() {
        Diagnostics.start()
        _ = AppUpdater.shared
        // `BurrowBolt /some/path` is a scan target, not a document to open.
        // Left to AppKit, the path becomes an open-file request and SwiftUI
        // then skips creating the main window entirely.
        UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO"])
    }

    var body: some Scene {
        WindowGroup("BurrowBolt") {
            ContentView()
                .preferredColorScheme(.dark)
        }
        .windowStyle(.automatic)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { AppUpdater.shared.check() }
            }
        }
        Settings { DiagnosticsSettings() }
    }
}
