import SwiftUI

struct PositionCorrectionSheet: View {
    @ObservedObject var model: PilotPresentationModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPiece = "红·炮"

    private let redPieces = ["帥", "仕", "相", "馬", "車", "炮", "兵"]
    private let blackPieces = ["將", "士", "象", "馬", "車", "砲", "卒"]

    var body: some View {
        VStack(spacing: 0) {
            ModalHeader(
                title: "任意局面识别与人工校正",
                subtitle: "以当前画面为基准，直接修正棋子或重新识别",
                symbolName: "viewfinder"
            )

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        CapsuleBadge(title: "红方走", color: CockpitPalette.red)
                        CapsuleBadge(title: "\(model.pieces.count) 枚棋子", color: CockpitPalette.green)
                        Spacer()
                        Text("单击交点放置 · 再次单击移除")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(CockpitPalette.secondaryText)
                    }

                    XiangqiBoardView(
                        pieces: model.pieces,
                        proposal: nil,
                        showsRecognitionOverlay: false,
                        onIntersectionTap: { coordinate in
                            model.editPiece(at: coordinate, token: selectedPiece)
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(10)
                    .background(Color.black.opacity(0.22))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(CockpitPalette.borderStrong, lineWidth: 1)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                correctionTools
                    .frame(width: 260)
            }
            .padding(18)

            ModalFooter {
                Button("取消") { dismiss() }
                    .buttonStyle(SecondaryActionButtonStyle())

                Button {
                    model.recognizePosition()
                } label: {
                    Label("重新识别", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SecondaryActionButtonStyle())

                Button {
                    model.applyCorrection()
                    dismiss()
                } label: {
                    Label("应用为可信局面", systemImage: "checkmark.seal.fill")
                }
                .buttonStyle(CockpitActionButtonStyle(color: CockpitPalette.cyan))
            }
        }
        .frame(width: 920, height: 690)
        .background(CockpitPalette.canvas)
        .preferredColorScheme(.dark)
    }

    private var correctionTools: some View {
        VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading, spacing: 9) {
                SectionLabel(title: "识别摘要")
                KeyValueRow(key: "来源", value: "本地视觉")
                KeyValueRow(key: "置信度", value: model.confidenceText, valueColor: CockpitPalette.green)
                KeyValueRow(key: "朝向", value: "红方在下")
                KeyValueRow(key: "下一手", value: "红方")
            }
            .padding(13)
            .cockpitPanel(cornerRadius: 12, raised: true)

            piecePalette(title: "红方棋子", pieces: redPieces, color: CockpitPalette.red)
            piecePalette(title: "黑方棋子", pieces: blackPieces, color: CockpitPalette.primaryText)

            Button {
                selectedPiece = "擦除"
            } label: {
                HStack {
                    Image(systemName: "eraser.fill")
                    Text("擦除棋子")
                    Spacer()
                    if selectedPiece == "擦除" {
                        Image(systemName: "checkmark")
                    }
                }
                .padding(.horizontal, 11)
                .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(selectedPiece == "擦除" ? CockpitPalette.amber : CockpitPalette.secondaryText)
            .background(Color.white.opacity(0.045))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            Spacer()

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "shield.lefthalf.filled")
                    .foregroundStyle(CockpitPalette.green)
                Text("应用后将重新进行象棋合法性校验，并把此局面设为新的恢复基准。")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(CockpitPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(11)
            .background(CockpitPalette.green.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func piecePalette(title: String, pieces: [String], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: title)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(pieces, id: \.self) { piece in
                    let token = "\(title.prefix(1))·\(piece)"
                    Button {
                        selectedPiece = token
                    } label: {
                        Text(piece)
                            .font(.system(size: 15, weight: .bold, design: .serif))
                            .frame(maxWidth: .infinity, minHeight: 31)
                            .background(selectedPiece == token ? color.opacity(0.16) : Color.white.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(selectedPiece == token ? color.opacity(0.55) : CockpitPalette.border, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(color)
                }
            }
        }
    }
}

struct ReviewSheet: View {
    @ObservedObject var model: PilotPresentationModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedMove = 1

    private let moves = [
        (1, "炮二平五", "炮８平５", "+0.32"),
        (2, "马二进三", "马８进７", "+0.21"),
        (3, "车一平二", "车９平８", "+0.28"),
        (4, "兵三进一", "卒３进１", "+0.16"),
        (5, "马八进七", "马２进３", "+0.24")
    ]

    var body: some View {
        VStack(spacing: 0) {
            ModalHeader(
                title: "复盘记录",
                subtitle: "逐手查看识别、引擎建议与人工接管记录",
                symbolName: "clock.arrow.circlepath"
            )

            HStack(spacing: 16) {
                VStack(spacing: 12) {
                    XiangqiBoardView(
                        pieces: model.pieces,
                        proposal: model.candidates.first,
                        showsRecognitionOverlay: false
                    )
                    .padding(10)
                    .background(Color.black.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    HStack(spacing: 8) {
                        Button(action: { selectedMove = max(1, selectedMove - 1) }) {
                            Image(systemName: "backward.end.fill")
                        }
                        Button(action: {}) {
                            Image(systemName: "play.fill")
                        }
                        Button(action: { selectedMove = min(moves.count, selectedMove + 1) }) {
                            Image(systemName: "forward.end.fill")
                        }
                        Text("第 \(selectedMove) 回合 / \(moves.count)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(CockpitPalette.secondaryText)
                            .padding(.leading, 5)
                        Spacer()
                        CapsuleBadge(title: "无异常", color: CockpitPalette.green, symbolName: "checkmark.circle.fill")
                    }
                    .buttonStyle(SecondaryActionButtonStyle(compact: true))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        SectionLabel(title: "着法列表")
                        Spacer()
                        CapsuleBadge(title: "本机记录", color: CockpitPalette.blue)
                    }

                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(moves, id: \.0) { move in
                                Button {
                                    selectedMove = move.0
                                } label: {
                                    HStack(spacing: 10) {
                                        Text("\(move.0)")
                                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                                            .foregroundStyle(selectedMove == move.0 ? CockpitPalette.cyan : CockpitPalette.tertiaryText)
                                            .frame(width: 22)
                                        Text(move.1)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Text(move.2)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Text(move.3)
                                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                                            .foregroundStyle(CockpitPalette.green)
                                    }
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(CockpitPalette.primaryText)
                                    .padding(.horizontal, 9)
                                    .frame(height: 36)
                                    .background(selectedMove == move.0 ? CockpitPalette.cyan.opacity(0.08) : Color.white.opacity(0.025))
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Divider().overlay(CockpitPalette.border)

                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(title: "本回合摘要")
                        KeyValueRow(key: "识别", value: "98.7%", valueColor: CockpitPalette.green)
                        KeyValueRow(key: "引擎耗时", value: "0.8 秒")
                        KeyValueRow(key: "操作模式", value: "确认")
                        KeyValueRow(key: "画面校验", value: "通过", valueColor: CockpitPalette.green)
                    }
                    .padding(12)
                    .cockpitPanel(cornerRadius: 11, raised: true)
                }
                .frame(width: 340)
            }
            .padding(18)

            ModalFooter {
                Button("关闭") { dismiss() }
                    .buttonStyle(SecondaryActionButtonStyle())
                Spacer()
                Button {
                } label: {
                    Label("导出棋谱", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(CockpitActionButtonStyle(color: CockpitPalette.blue))
            }
        }
        .frame(width: 960, height: 700)
        .background(CockpitPalette.canvas)
        .preferredColorScheme(.dark)
    }
}

struct RecoverySheet: View {
    @ObservedObject var model: PilotPresentationModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ModalHeader(
                title: "异常恢复中心",
                subtitle: "先恢复可信局面，再重新开放窗口操作",
                symbolName: "cross.case.fill",
                color: CockpitPalette.amber
            )

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(CockpitPalette.amber.opacity(0.12))
                            Image(systemName: "rectangle.on.rectangle.slash.fill")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(CockpitPalette.amber)
                        }
                        .frame(width: 48, height: 48)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("检测到一次画面遮挡")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(CockpitPalette.primaryText)
                            Text("19:39:08 · 系统已暂停，未执行重复点击")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(CockpitPalette.secondaryText)
                        }
                    }
                    .padding(13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(CockpitPalette.amber.opacity(0.055))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    HStack(spacing: 10) {
                        snapshotCard(title: "最后可信局面", detail: "19:39:07 · 32 枚", color: CockpitPalette.green)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(CockpitPalette.tertiaryText)
                        snapshotCard(title: "当前画面", detail: "遮挡已移除", color: CockpitPalette.blue)
                    }

                    XiangqiBoardView(
                        pieces: model.pieces,
                        proposal: nil,
                        showsRecognitionOverlay: true,
                        compact: true
                    )
                    .padding(8)
                    .background(Color.black.opacity(0.22))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel(title: "恢复检查")
                    recoveryCheck("目标窗口", detail: "已重新锁定", isComplete: true)
                    recoveryCheck("棋盘边界", detail: "偏差 0.6 px", isComplete: true)
                    recoveryCheck("棋子局面", detail: "32 枚一致", isComplete: true)
                    recoveryCheck("当前轮次", detail: "红方走", isComplete: true)
                    recoveryCheck("窗口操作", detail: "仍保持锁定", isComplete: false)

                    Divider().overlay(CockpitPalette.border)

                    VStack(alignment: .leading, spacing: 7) {
                        Text("恢复策略")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(CockpitPalette.primaryText)
                        Text("使用当前画面重新识别，并将结果与最后可信局面比较。恢复后保持暂停，由你手动继续。")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(CockpitPalette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(11)
                    .background(Color.white.opacity(0.035))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    Spacer()

                    Button {
                        model.recognizePosition()
                    } label: {
                        Label("重新识别当前画面", systemImage: "viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryActionButtonStyle())

                    Button {
                        model.markRecovered()
                        dismiss()
                    } label: {
                        Label("设为可信局面并恢复", systemImage: "checkmark.shield.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(CockpitActionButtonStyle(color: CockpitPalette.green))
                }
                .padding(14)
                .frame(width: 300)
                .frame(maxHeight: .infinity)
                .cockpitPanel(cornerRadius: 14, raised: true)
            }
            .padding(18)

            ModalFooter {
                Button("关闭并保持暂停") { dismiss() }
                    .buttonStyle(SecondaryActionButtonStyle())
                Spacer()
                Text("未知弹窗不会被自动点击")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CockpitPalette.amber)
            }
        }
        .frame(width: 900, height: 680)
        .background(CockpitPalette.canvas)
        .preferredColorScheme(.dark)
    }

    private func snapshotCard(title: String, detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                StatusDot(color: color)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CockpitPalette.primaryText)
            }
            Text(detail)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(CockpitPalette.secondaryText)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(color.opacity(0.16), lineWidth: 1)
        }
    }

    private func recoveryCheck(_ title: String, detail: String, isComplete: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "lock.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isComplete ? CockpitPalette.green : CockpitPalette.amber)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CockpitPalette.primaryText)
                Text(detail)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(CockpitPalette.secondaryText)
            }
            Spacer()
        }
    }
}

struct ModalHeader: View {
    let title: String
    let subtitle: String
    let symbolName: String
    var color: Color = CockpitPalette.cyan

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(color.opacity(0.12))
                Image(systemName: symbolName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(color)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(CockpitPalette.primaryText)
                Text(subtitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(CockpitPalette.secondaryText)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .frame(height: 64)
        .background(CockpitPalette.sidebar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(CockpitPalette.border).frame(height: 1)
        }
    }
}

struct ModalFooter<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 10) {
            content
        }
        .padding(.horizontal, 18)
        .frame(height: 62)
        .background(CockpitPalette.sidebar)
        .overlay(alignment: .top) {
            Rectangle().fill(CockpitPalette.border).frame(height: 1)
        }
    }
}
