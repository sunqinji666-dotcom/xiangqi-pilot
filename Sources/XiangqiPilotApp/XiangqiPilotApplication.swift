import SwiftUI

@main
struct XiangqiPilotApplication: App {
    @StateObject private var runtime = PilotRuntime()

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
