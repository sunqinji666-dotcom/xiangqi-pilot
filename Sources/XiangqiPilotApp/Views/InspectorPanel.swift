import SwiftUI

struct InspectorPanel: View {
    @ObservedObject var model: PilotPresentationModel
    let openRecovery: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                recognitionStatus
                candidatesSection
                controlModeSection
                sourcesSection
                safetySection
            }
            .padding(14)
        }
        .scrollIndicators(.hidden)
        .frame(width: 322)
        .background(CockpitPalette.sidebar)
        .overlay(alignment: .leading) {
            Rectangle().fill(CockpitPalette.border).frame(width: 1)
        }
    }

    private var recognitionStatus: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel(title: "当前状态")
                Spacer()
                CapsuleBadge(
                    title: model.isEmergencyStopped ? "已锁定" : (model.isPaused ? "已暂停" : "运行中"),
                    color: model.isEmergencyStopped ? CockpitPalette.red : (model.isPaused ? CockpitPalette.amber : CockpitPalette.green),
                    symbolName: model.isEmergencyStopped ? "lock.fill" : (model.isPaused ? "pause.fill" : "waveform.path.ecg")
                )
            }

            Text(model.headlineStatus)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(CockpitPalette.primaryText)

            Text(model.isEmergencyStopped
                 ? "窗口操作已全部禁用，解除锁定后仍需重新识别。"
                 : "当前\(model.sideToMove == .red ? "红方" : "黑方")走；已锁定目标窗口和棋盘边界。")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(CockpitPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.07), lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: model.confidence)
                        .stroke(
                            model.confidence > 0.97 ? CockpitPalette.green : CockpitPalette.amber,
                            style: StrokeStyle(lineWidth: 6, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    Text(model.confidenceText)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(CockpitPalette.primaryText)
                }
                .frame(width: 58, height: 58)

                VStack(alignment: .leading, spacing: 5) {
                    Text("局面可信度 · \(model.confidenceBasis)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CockpitPalette.primaryText)
                    Text("棋子 \(model.pieces.count) 枚 · 网格偏差 \(gridDeviationText)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(CockpitPalette.secondaryText)
                    HStack(spacing: 5) {
                        StatusDot(color: model.isPositionTrusted ? CockpitPalette.green : CockpitPalette.amber)
                        Text(model.isPositionTrusted ? "可信基准已建立" : "等待安全确认")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(model.isPositionTrusted ? CockpitPalette.green : CockpitPalette.amber)
                    }
                }
            }
        }
        .padding(13)
        .cockpitPanel(cornerRadius: 13, raised: true)
    }

    private var candidatesSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel(title: "候选着法", detail: model.engineSource.title)

            ForEach(Array(model.candidates.enumerated()), id: \.element.id) { index, candidate in
                CandidateMoveRow(
                    rank: index + 1,
                    candidate: candidate,
                    isSelected: candidate.id == model.selectedCandidateID
                ) {
                    model.chooseCandidate(candidate)
                }
            }
        }
    }

    private var gridDeviationText: String {
        guard let value = model.gridDeviationPixels else { return "未测量" }
        return "\(value.formatted(.number.precision(.fractionLength(1)))) px"
    }

    private var controlModeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "操作模式")

            Picker("操作模式", selection: $model.controlMode) {
                ForEach(ControlMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            HStack(alignment: .top, spacing: 7) {
                Image(systemName: modeSymbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(modeColor)
                    .padding(.top, 1)
                Text(model.controlMode.detail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(CockpitPalette.secondaryText)
                Spacer()
            }

            Button {
                model.confirmSelectedMove()
            } label: {
                HStack {
                    Image(systemName: model.controlMode == .assist ? "sparkles" : "cursorarrow.click.2")
                    Text(primaryActionTitle)
                    Spacer()
                    if model.controlMode == .confirm {
                        Text(model.selectedCandidate.notation)
                            .font(.system(size: 11, weight: .bold))
                    }
                }
                .padding(.horizontal, 2)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(CockpitActionButtonStyle(color: modeColor))
            .disabled(
                model.isPaused
                    || model.isEmergencyStopped
                    || model.phase != .previewing
            )
            .opacity(
                model.isPaused
                    || model.isEmergencyStopped
                    || model.phase != .previewing
                    ? 0.42 : 1
            )
        }
        .padding(13)
        .cockpitPanel(cornerRadius: 13)
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionLabel(title: "引擎与模型", detail: "可选接入")

            sourceMenuRow(
                title: "局面识别",
                symbolName: "viewfinder.circle",
                value: "本地视觉",
                color: CockpitPalette.green
            )

            VStack(spacing: 5) {
                HStack(spacing: 9) {
                    Image(systemName: "cpu")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CockpitPalette.blue)
                        .frame(width: 18)
                    Text("决策引擎")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CockpitPalette.secondaryText)
                    Spacer()
                    Picker("决策引擎", selection: $model.engineSource) {
                        ForEach(EngineSource.allCases) { source in
                            Text(source.title).tag(source)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(maxWidth: 148, alignment: .trailing)
                }

                HStack(spacing: 9) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(model.modelSource == .off ? CockpitPalette.tertiaryText : CockpitPalette.cyan)
                        .frame(width: 18)
                    Text("大模型增强")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CockpitPalette.secondaryText)
                    Spacer()
                    Picker("大模型增强", selection: $model.modelSource) {
                        ForEach(ModelSource.allCases) { source in
                            Text(source.title).tag(source)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(maxWidth: 148, alignment: .trailing)
                }
            }

            if model.modelSource != .off {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(CockpitPalette.cyan)
                    Text("大模型仅在本地识别低置信度时复核局面；结果仍须通过棋规与画面校验。")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(CockpitPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(9)
                .background(CockpitPalette.cyan.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                if let billing = model.lastModelBilling {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("最近一次模型调用")
                            Spacer()
                            Text("¥\(billing.costCNY.formatted(.number.precision(.fractionLength(6))))")
                                .foregroundStyle(CockpitPalette.green)
                        }
                        Text("\(billing.modelID) · 输入 \(billing.inputTokens) / 输出 \(billing.outputTokens) Token")
                        Text("\(billing.durationMilliseconds) ms · 本局累计 ¥\(model.modelSessionCostCNY.formatted(.number.precision(.fractionLength(6))))")
                        Text("阿里百炼官网费率 · \(billing.pricingUpdatedAt.formatted(date: .numeric, time: .omitted)) 更新")
                            .foregroundStyle(CockpitPalette.tertiaryText)
                    }
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(CockpitPalette.secondaryText)
                    .padding(9)
                    .background(Color.white.opacity(0.025))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Text("尚未调用云端模型 · 本局累计 ¥0.000000")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(CockpitPalette.tertiaryText)
                }
            }
        }
        .padding(13)
        .cockpitPanel(cornerRadius: 13)
    }

    private var safetySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(title: "安全闸")
                Spacer()
                Button("异常恢复", action: openRecovery)
                    .font(.system(size: 10, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(CockpitPalette.amber)
            }

            safetyRow(
                "目标窗口锁定",
                detail: model.source.isLocked ? "通过" : "未锁定",
                color: model.source.isLocked ? CockpitPalette.green : CockpitPalette.amber
            )
            safetyRow(
                "局面可信基准",
                detail: model.isPositionTrusted ? "通过" : "等待",
                color: model.isPositionTrusted ? CockpitPalette.green : CockpitPalette.amber
            )
            safetyRow("点击后画面校验", detail: "必需", color: CockpitPalette.blue)
            safetyRow("失败自动重试", detail: "关闭", color: CockpitPalette.secondaryText)
        }
        .padding(13)
        .cockpitPanel(cornerRadius: 13)
    }

    private var modeColor: Color {
        switch model.controlMode {
        case .assist: CockpitPalette.blue
        case .confirm: CockpitPalette.cyan
        case .automatic: CockpitPalette.amber
        }
    }

    private var modeSymbol: String {
        switch model.controlMode {
        case .assist: "lightbulb.fill"
        case .confirm: "checkmark.circle.fill"
        case .automatic: "bolt.fill"
        }
    }

    private var primaryActionTitle: String {
        switch model.controlMode {
        case .assist: "采纳建议"
        case .confirm: "确认落子"
        case .automatic: "自动模式待命"
        }
    }

    private func sourceMenuRow(
        title: String,
        symbolName: String,
        value: String,
        color: Color
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 18)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(CockpitPalette.secondaryText)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CockpitPalette.primaryText)
        }
    }

    private func safetyRow(_ title: String, detail: String, color: Color) -> some View {
        HStack(spacing: 7) {
            StatusDot(color: color)
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(CockpitPalette.secondaryText)
            Spacer()
            Text(detail)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
        }
    }
}

private struct CandidateMoveRow: View {
    let rank: Int
    let candidate: CandidateMove
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text("\(rank)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(isSelected ? CockpitPalette.cyan : CockpitPalette.tertiaryText)
                    .frame(width: 22, height: 22)
                    .background((isSelected ? CockpitPalette.cyan : Color.white).opacity(0.08))
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.notation)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(CockpitPalette.primaryText)
                    Text(candidate.reason)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(CockpitPalette.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(candidate.evaluation)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(isSelected ? CockpitPalette.green : CockpitPalette.secondaryText)
                    Text("\(candidate.score)%")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(CockpitPalette.tertiaryText)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 48)
            .background(isSelected ? CockpitPalette.cyan.opacity(0.065) : Color.white.opacity(0.025))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? CockpitPalette.cyan.opacity(0.28) : CockpitPalette.border, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}
