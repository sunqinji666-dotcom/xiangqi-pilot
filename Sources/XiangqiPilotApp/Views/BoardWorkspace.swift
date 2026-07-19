import SwiftUI

struct BoardWorkspace: View {
    @ObservedObject var model: PilotPresentationModel
    let openCorrection: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            workspaceToolbar
            previewSurface
            moveSummary
        }
        .padding(12)
        .cockpitPanel(cornerRadius: 16)
    }

    private var workspaceToolbar: some View {
        HStack(spacing: 10) {
            Picker("预览模式", selection: $model.previewMode) {
                ForEach(PreviewMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 208)

            CapsuleBadge(title: "红方走", color: CockpitPalette.red, symbolName: "circle.fill")
            CapsuleBadge(title: "\(model.pieces.count) 枚已识别", color: CockpitPalette.green, symbolName: "checkmark.seal.fill")

            Spacer()

            Button {
                model.recognizePosition()
            } label: {
                Label("识别当前局面", systemImage: "viewfinder")
            }
            .buttonStyle(SecondaryActionButtonStyle(compact: true))

            Button(action: openCorrection) {
                Label("人工校正", systemImage: "hand.draw")
            }
            .buttonStyle(SecondaryActionButtonStyle(compact: true))
        }
    }

    private var previewSurface: some View {
        VStack(spacing: 0) {
            if model.previewMode == .live {
                windowChrome
            }

            ZStack(alignment: .topTrailing) {
                LinearGradient(
                    colors: [Color.black.opacity(0.32), CockpitPalette.canvas.opacity(0.94)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                if model.previewMode == .live, let liveImage = model.liveImage {
                    Image(nsImage: liveImage)
                        .resizable()
                        .scaledToFit()
                        .padding(10)
                } else {
                    XiangqiBoardView(
                        pieces: model.pieces,
                        proposal: model.selectedCandidate,
                        showsRecognitionOverlay: false
                    )
                    .padding(.vertical, 8)
                }

                VStack(alignment: .trailing, spacing: 7) {
                    CapsuleBadge(
                        title: model.previewMode == .live ? "持久窗口视觉流" : "数字局面与拟落点",
                        color: model.previewMode == .live ? CockpitPalette.cyan : CockpitPalette.blue,
                        symbolName: model.previewMode == .live ? "eye.fill" : "checkerboard.rectangle"
                    )
                    Text("拟落点以青色标记，不代表已点击")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(CockpitPalette.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.black.opacity(0.34))
                        .clipShape(Capsule())
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(CockpitPalette.borderStrong, lineWidth: 1)
        }
        .frame(minHeight: 390)
    }

    private var windowChrome: some View {
        HStack(spacing: 7) {
            Circle().fill(Color(red: 1, green: 0.36, blue: 0.34)).frame(width: 8, height: 8)
            Circle().fill(Color(red: 1, green: 0.74, blue: 0.26)).frame(width: 8, height: 8)
            Circle().fill(Color(red: 0.31, green: 0.79, blue: 0.39)).frame(width: 8, height: 8)

            Spacer()

            Image(systemName: "macwindow")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(CockpitPalette.tertiaryText)
            Text("\(model.source.applicationName) — \(model.source.windowTitle)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(CockpitPalette.secondaryText)

            Spacer()

            HStack(spacing: 4) {
                StatusDot(color: CockpitPalette.green)
                Text("窗口已锁定")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(CockpitPalette.green)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Color.white.opacity(0.045))
        .overlay(alignment: .bottom) {
            Rectangle().fill(CockpitPalette.border).frame(height: 1)
        }
    }

    private var moveSummary: some View {
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(CockpitPalette.cyan.opacity(0.12))
                    Image(systemName: "scope")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(CockpitPalette.cyan)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text("拟落点")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(CockpitPalette.secondaryText)
                    Text(model.selectedCandidate.notation)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(CockpitPalette.primaryText)
                }
            }

            Divider()
                .overlay(CockpitPalette.borderStrong)
                .frame(height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedCandidate.reason)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(CockpitPalette.primaryText)
                Text("引擎评估 \(model.selectedCandidate.evaluation) · 规则校验通过")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(CockpitPalette.secondaryText)
            }

            Spacer()

            HStack(spacing: 5) {
                Image(systemName: "cursorarrow.motionlines")
                Text("目标交点 5 路 · 底线炮位")
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(CockpitPalette.cyan)
        }
        .padding(.horizontal, 11)
        .frame(height: 50)
        .background(Color.white.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct EventTimelineView: View {
    let events: [TimelineEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                SectionLabel(title: "事件时间线", detail: "最近活动")
                Spacer()
                HStack(spacing: 5) {
                    Image(systemName: "externaldrive.badge.checkmark")
                    Text("仅本机记录")
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(CockpitPalette.tertiaryText)
            }

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(events.prefix(8)) { event in
                        TimelineEventCard(event: event)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(12)
        .frame(height: 126)
        .cockpitPanel(cornerRadius: 14)
    }
}

private struct TimelineEventCard: View {
    let event: TimelineEvent

    private var color: Color {
        switch event.tone {
        case .neutral: CockpitPalette.blue
        case .success: CockpitPalette.green
        case .attention: CockpitPalette.amber
        case .danger: CockpitPalette.red
        }
    }

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(color.opacity(0.11))
                Image(systemName: event.symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(event.time)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(CockpitPalette.tertiaryText)
                    Text(event.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CockpitPalette.primaryText)
                }
                Text(event.detail)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(CockpitPalette.secondaryText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 9)
        .frame(width: 232, height: 50, alignment: .leading)
        .background(Color.white.opacity(0.032))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(CockpitPalette.border, lineWidth: 1)
        }
    }
}
