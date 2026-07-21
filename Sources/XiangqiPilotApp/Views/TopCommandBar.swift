import SwiftUI

struct TopCommandBar: View {
    @ObservedObject var model: PilotPresentationModel

    private var statusColor: Color {
        if model.isEmergencyStopped { return CockpitPalette.red }
        if model.isPaused { return CockpitPalette.amber }
        return CockpitPalette.green
    }

    var body: some View {
        HStack(spacing: 18) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [CockpitPalette.blue, CockpitPalette.cyan],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "scope")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 38, height: 38)
                .shadow(color: CockpitPalette.blue.opacity(0.28), radius: 12, y: 4)

                VStack(alignment: .leading, spacing: 2) {
                    Text("棋局驾驶舱")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(CockpitPalette.primaryText)
                    HStack(spacing: 5) {
                        StatusDot(color: statusColor, isPulsing: !model.isPaused)
                        Text(model.headlineStatus)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(statusColor)
                    }
                }
            }
            .frame(width: 214, alignment: .leading)

            PhaseRail(currentPhase: model.phase, isPaused: model.isPaused || model.isEmergencyStopped)
                .frame(maxWidth: .infinity)

            HStack(spacing: 9) {
                Button {
                    model.returnHome()
                } label: {
                    Label("返回首页", systemImage: "house.fill")
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .keyboardShortcut("h", modifiers: [.command, .shift])

                if model.isEmergencyStopped {
                    Button {
                        model.resumeAfterStop()
                    } label: {
                        Label("解除锁定", systemImage: "lock.open")
                    }
                    .buttonStyle(SecondaryActionButtonStyle())
                }

                Button {
                    model.togglePause()
                } label: {
                    Label(model.isPaused ? "继续" : "暂停", systemImage: model.isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(CockpitActionButtonStyle(color: CockpitPalette.amber))
                .disabled(model.isEmergencyStopped)
                .opacity(model.isEmergencyStopped ? 0.45 : 1)
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Button {
                    model.emergencyStop()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "octagon.fill")
                        Text("急停")
                        Text("⌃⌥Esc")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.72))
                    }
                }
                .buttonStyle(CockpitActionButtonStyle(color: CockpitPalette.red))
                .keyboardShortcut(.escape, modifiers: [.control, .option])
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 68)
        .background(CockpitPalette.sidebar.opacity(0.97))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(CockpitPalette.border)
                .frame(height: 1)
        }
    }
}

private struct PhaseRail: View {
    let currentPhase: PilotPhase
    let isPaused: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(PilotPhase.allCases) { phase in
                PhaseNode(
                    phase: phase,
                    isCurrent: phase == currentPhase,
                    isComplete: phase.rawValue < currentPhase.rawValue,
                    isPaused: isPaused
                )

                if phase != PilotPhase.allCases.last {
                    Rectangle()
                        .fill(
                            phase.rawValue < currentPhase.rawValue
                                ? CockpitPalette.blue.opacity(0.65)
                                : CockpitPalette.borderStrong
                        )
                        .frame(maxWidth: 30, minHeight: 1, maxHeight: 1)
                }
            }
        }
        .padding(.horizontal, 6)
    }
}

private struct PhaseNode: View {
    let phase: PilotPhase
    let isCurrent: Bool
    let isComplete: Bool
    let isPaused: Bool

    private var nodeColor: Color {
        if isPaused && isCurrent { return CockpitPalette.amber }
        if isCurrent || isComplete { return CockpitPalette.blue }
        return CockpitPalette.tertiaryText
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(nodeColor.opacity(isCurrent ? 0.18 : 0.08))
                    .frame(width: 25, height: 25)
                Image(systemName: isComplete ? "checkmark" : phase.symbolName)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(nodeColor)
            }
            Text(phase.title)
                .font(.system(size: 10, weight: isCurrent ? .semibold : .medium))
                .foregroundStyle(isCurrent ? CockpitPalette.primaryText : CockpitPalette.secondaryText)
        }
        .frame(minWidth: 48)
    }
}
