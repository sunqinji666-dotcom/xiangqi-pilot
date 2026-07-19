import SwiftUI

struct PilotRootView: View {
    @ObservedObject var runtime: PilotRuntime

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if runtime.setupStep == .ready, let blockingError = runtime.blockingError {
                    RuntimeBlockingErrorBanner(message: blockingError)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                PilotDashboardView(model: runtime.presentation)
            }
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
        .animation(.easeOut(duration: 0.2), value: runtime.blockingError)
    }
}

private struct RuntimeBlockingErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 15, weight: .bold))

            VStack(alignment: .leading, spacing: 2) {
                Text("自动操作已安全暂停")
                    .font(.system(size: 12, weight: .bold))
                Text(message)
                    .font(.system(.caption, design: .monospaced, weight: .medium))
                    .textSelection(.enabled)
            }

            Spacer(minLength: 8)
        }
        .foregroundStyle(CockpitPalette.primaryText)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CockpitPalette.red.opacity(0.20))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(CockpitPalette.red.opacity(0.75))
                .frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pilot-runtime-blocking-error")
    }
}
