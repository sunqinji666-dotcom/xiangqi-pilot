import SwiftUI

struct PilotRootView: View {
    @ObservedObject var runtime: PilotRuntime

    var body: some View {
        ZStack {
            PilotDashboardView(model: runtime.presentation)
                .blur(radius: runtime.setupStep == .ready ? 0 : 2.5)
                .allowsHitTesting(runtime.setupStep == .ready)

            if runtime.setupStep != .ready {
                Color.black.opacity(0.58).ignoresSafeArea()
                SetupWizardView(runtime: runtime)
                    .transition(.scale(scale: 0.98).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: runtime.setupStep)
        .task {
            await runtime.bootstrap()
        }
        .task(id: runtime.setupStep) {
            guard runtime.setupStep == .permissions else { return }
            while !Task.isCancelled && runtime.setupStep == .permissions {
                runtime.refreshPermissionState()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pilotTogglePause)) { _ in
            runtime.presentation.togglePause()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pilotEmergencyStop)) { _ in
            runtime.presentation.emergencyStop()
        }
    }
}
