import SwiftUI

struct CockpitSidebar: View {
    @ObservedObject var model: PilotPresentationModel
    let openCorrection: () -> Void
    let openReview: () -> Void
    let openRecovery: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            sourceCard

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(title: "棋种")
                ForEach(GameKind.allCases) { game in
                    gameRow(game)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(title: "工作区")

                workspaceButton(.cockpit) {
                    model.activeWorkspace = .cockpit
                }
                workspaceButton(.correction, action: openCorrection)
                workspaceButton(.review, action: openReview)
                workspaceButton(.recovery, action: openRecovery)
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(title: "当前棋局", detail: "实时")
                KeyValueRow(
                    key: "当前执棋",
                    value: model.displayedTurnText.replacingOccurrences(of: "走", with: ""),
                    valueColor: model.selectedGame == .xiangqi && model.sideToMove == .red
                        ? CockpitPalette.red
                        : CockpitPalette.primaryText
                )
                KeyValueRow(
                    key: "当前轮次",
                    value: model.displayedTurnText
                )
                KeyValueRow(key: "规则", value: model.displayedRuleText)
                KeyValueRow(key: "棋子", value: "\(model.displayedPieceCount) 枚")
            }
            .padding(12)
            .cockpitPanel(cornerRadius: 12, raised: true)

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(CockpitPalette.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text("仅本机处理")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CockpitPalette.primaryText)
                    Text("画面默认不落盘")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(CockpitPalette.tertiaryText)
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CockpitPalette.green.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(14)
        .frame(width: 230)
        .background(CockpitPalette.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(CockpitPalette.border)
                .frame(width: 1)
        }
    }

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "目标窗口", trailingSymbol: "chevron.up.chevron.down")

            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(CockpitPalette.blue.opacity(0.12))
                    Image(systemName: "macwindow")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(CockpitPalette.blue)
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 3) {
                    Text(model.source.applicationName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CockpitPalette.primaryText)
                    Text(model.source.windowTitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(CockpitPalette.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                StatusDot(color: CockpitPalette.green)
                Text("窗口已锁定")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CockpitPalette.green)
                Spacer()
                Text("60 Hz")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(CockpitPalette.tertiaryText)
            }
        }
        .padding(12)
        .cockpitPanel(cornerRadius: 12, raised: true)
    }

    private func gameRow(_ game: GameKind) -> some View {
        Button {
            guard game.isAvailable else { return }
            model.selectedGame = game
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(game == model.selectedGame ? CockpitPalette.blue.opacity(0.15) : Color.white.opacity(0.035))
                    Image(systemName: game.symbolName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(
                            game.isAvailable
                                ? (game == model.selectedGame ? CockpitPalette.blue : CockpitPalette.secondaryText)
                                : CockpitPalette.tertiaryText
                        )
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(game.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(game.isAvailable ? CockpitPalette.primaryText : CockpitPalette.tertiaryText)
                    Text(game.subtitle)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(game.isAvailable ? CockpitPalette.secondaryText : CockpitPalette.tertiaryText)
                }

                Spacer()

                if game == model.selectedGame {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CockpitPalette.blue)
                } else if !game.isAvailable {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(CockpitPalette.tertiaryText)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 44)
            .background(game == model.selectedGame ? CockpitPalette.blue.opacity(0.07) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(game == model.selectedGame ? CockpitPalette.blue.opacity(0.2) : Color.clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(!game.isAvailable)
        .help(game.isAvailable ? game.title : "\(game.title)即将推出")
    }

    private func workspaceButton(
        _ destination: WorkspaceDestination,
        action: @escaping () -> Void
    ) -> some View {
        let isActive = destination == model.activeWorkspace

        return Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: destination.symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 18)
                    .foregroundStyle(isActive ? CockpitPalette.blue : CockpitPalette.secondaryText)
                Text(destination.title)
                    .font(.system(size: 12, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(isActive ? CockpitPalette.primaryText : CockpitPalette.secondaryText)
                Spacer()
                if destination == .recovery {
                    Circle()
                        .fill(CockpitPalette.amber)
                        .frame(width: 6, height: 6)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(CockpitPalette.tertiaryText)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(isActive ? Color.white.opacity(0.055) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
