import SwiftUI
import Darwin

@main
struct XiangqiPilotApplication: App {
    @StateObject private var runtime = PilotRuntime()

    init() {
        // Installation-only development bootstrap. It imports the API key from
        // the user-provided Alibaba CSV into the local development cache and
        // exits before SwiftUI creates a window. No credential is printed.
        if CommandLine.arguments.contains("--bootstrap-development-credential") {
            let store = APIKeyStore()
            let imported = try? store.load(account: AlibabaBailianConfiguration.keychainAccount)
            exit(imported == nil ? 1 : 0)
        }
    }

    var body: some Scene {
        WindowGroup("棋局驾驶舱") {
            PilotRootView(runtime: runtime)
        }
        .defaultSize(width: 1380, height: 860)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("对局") {
                Button("暂停 / 继续") {
                    NotificationCenter.default.post(name: .pilotTogglePause, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Button("紧急停止") {
                    NotificationCenter.default.post(name: .pilotEmergencyStop, object: nil)
                }
                .keyboardShortcut(.escape, modifiers: [.control, .option])
            }
        }
    }
}

extension Notification.Name {
    static let pilotTogglePause = Notification.Name("xiangqi-pilot.toggle-pause")
    static let pilotEmergencyStop = Notification.Name("xiangqi-pilot.emergency-stop")
}
