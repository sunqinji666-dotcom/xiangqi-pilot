import SwiftUI
import XiangqiCore

struct SetupWizardView: View {
    @ObservedObject var runtime: PilotRuntime

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(CockpitPalette.border)

            Group {
                switch runtime.setupStep {
                case .permissions: PermissionsSetupStep(runtime: runtime)
                case .window: WindowSetupStep(runtime: runtime)
                case .calibration: CalibrationSetupStep(runtime: runtime)
                case .position: PositionSetupStep(runtime: runtime)
                case .ready: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().overlay(CockpitPalette.border)
            footer
        }
        .frame(width: 960, height: 720)
        .background(CockpitPalette.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(CockpitPalette.borderStrong, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.45), radius: 36, y: 18)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [CockpitPalette.blue, CockpitPalette.cyan],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "scope")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text("启动中国象棋副驾")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(CockpitPalette.primaryText)
                Text("只绑定你选中的窗口，每步落子都经过视觉复核")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(CockpitPalette.secondaryText)
            }

            Spacer()

            HStack(spacing: 7) {
                ForEach(SetupStep.allCases.dropLast(), id: \.rawValue) { step in
                    VStack(spacing: 5) {
                        Circle()
                            .fill(step.rawValue <= runtime.setupStep.rawValue ? CockpitPalette.cyan : CockpitPalette.borderStrong)
                            .frame(width: step == runtime.setupStep ? 10 : 7, height: step == runtime.setupStep ? 10 : 7)
                        Text(step.title)
                            .font(.system(size: 9, weight: step == runtime.setupStep ? .bold : .medium))
                            .foregroundStyle(step == runtime.setupStep ? CockpitPalette.primaryText : CockpitPalette.tertiaryText)
                    }
                    .frame(width: 72)
                }
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 76)
        .background(CockpitPalette.sidebar)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            StatusDot(
                color: runtime.blockingError == nil ? CockpitPalette.green : CockpitPalette.amber,
                isPulsing: runtime.isBusy
            )
            Text(runtime.blockingError ?? runtime.statusMessage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(runtime.blockingError == nil ? CockpitPalette.secondaryText : CockpitPalette.amber)
                .lineLimit(2)
            Spacer()
            if runtime.isBusy {
                ProgressView().controlSize(.small)
            }
            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                Text("默认本机处理·不保存原始画面")
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(CockpitPalette.green)
        }
        .padding(.horizontal, 22)
        .frame(height: 52)
        .background(CockpitPalette.sidebar)
    }
}

private struct PermissionsSetupStep: View {
    @ObservedObject var runtime: PilotRuntime

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Text("先完成两项 macOS 授权")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(CockpitPalette.primaryText)
            Text("屏幕录制只用于读取指定棋局窗口；辅助功能只用于执行已通过安全审批的起点和终点点击。")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(CockpitPalette.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 620)

            HStack(spacing: 16) {
                permissionCard(
                    title: "屏幕录制",
                    detail: "持续捕获被选中的象棋窗口",
                    symbol: "rectangle.inset.filled.and.person.filled",
                    granted: runtime.hasScreenRecordingPermission,
                    action: runtime.requestScreenRecordingPermission
                )
                permissionCard(
                    title: "辅助功能",
                    detail: "在棋盘白名单区域内执行落子",
                    symbol: "cursorarrow.click.2",
                    granted: runtime.hasAccessibilityPermission,
                    action: runtime.requestAccessibilityPermission
                )
            }
            .frame(maxWidth: 700)

            Text("如果系统设置中已经开启，但这里仍显示“等待授权”，请重新启动同一个应用，不要反复点击授权。")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(runtime.permissionMayRequireRelaunch ? CockpitPalette.amber : CockpitPalette.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 620)

            HStack(spacing: 12) {
                Button {
                    runtime.refreshPermissionState()
                    if runtime.hasScreenRecordingPermission && runtime.hasAccessibilityPermission {
                        Task { await runtime.refreshWindows() }
                    }
                } label: {
                    Label("重新检测", systemImage: "arrow.clockwise")
                        .frame(width: 150)
                }
                .buttonStyle(CockpitActionButtonStyle(color: CockpitPalette.cyan))

                Button {
                    runtime.relaunchApplication()
                } label: {
                    Label("重新启动应用", systemImage: "power")
                        .frame(width: 170)
                }
                .buttonStyle(SecondaryActionButtonStyle())
            }
            Spacer()
        }
        .padding(28)
    }

    private func permissionCard(
        title: String,
        detail: String,
        symbol: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(granted ? CockpitPalette.green : CockpitPalette.blue)
                Spacer()
                CapsuleBadge(
                    title: granted ? "已授权" : "等待授权",
                    color: granted ? CockpitPalette.green : CockpitPalette.amber,
                    symbolName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
                )
            }
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(CockpitPalette.primaryText)
            Text(detail)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(CockpitPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Button(granted ? "已完成" : "打开系统授权", action: action)
                .buttonStyle(SecondaryActionButtonStyle())
                .disabled(granted)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .cockpitPanel(cornerRadius: 15, raised: true)
    }
}

private struct WindowSetupStep: View {
    @ObservedObject var runtime: PilotRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("选择正在运行的象棋窗口")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(CockpitPalette.primaryText)
                    Text("程序只会绑定一个具体 windowID，不会监看整个桌面。")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CockpitPalette.secondaryText)
                }
                Spacer()
                Button {
                    Task { await runtime.refreshWindows() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SecondaryActionButtonStyle())
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(runtime.availableWindows) { window in
                        Button {
                            Task { await runtime.selectWindow(window) }
                        } label: {
                            HStack(spacing: 13) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(CockpitPalette.blue.opacity(0.10))
                                    Image(systemName: "macwindow")
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundStyle(CockpitPalette.blue)
                                }
                                .frame(width: 42, height: 42)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(window.applicationName)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(CockpitPalette.primaryText)
                                    Text(window.title.isEmpty ? "未命名窗口" : window.title)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(CockpitPalette.secondaryText)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text("\(Int(window.frame.width)) × \(Int(window.frame.height))")
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(CockpitPalette.tertiaryText)
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(CockpitPalette.cyan)
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 62)
                            .background(Color.white.opacity(0.032))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(CockpitPalette.border, lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if runtime.availableWindows.isEmpty && !runtime.isBusy {
                ContentUnavailableView(
                    "没有可选窗口",
                    systemImage: "macwindow.badge.plus",
                    description: Text("请先打开一个象棋程序或网页，然后刷新。")
                )
            }
        }
        .padding(24)
    }
}

private struct CalibrationSetupStep: View {
    @ObservedObject var runtime: PilotRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("标定棋盘四角")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(CockpitPalette.primaryText)
                    Text("将四个青色控制点拖到 9×10 棋盘的最外侧交叉点。")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CockpitPalette.secondaryText)
                }
                Spacer()
                CapsuleBadge(title: "仅棋盘 ROI", color: CockpitPalette.green, symbolName: "lock.shield.fill")
            }

            CalibrationCanvas(image: runtime.latestImage, corners: $runtime.normalizedCorners)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.34))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(CockpitPalette.borderStrong, lineWidth: 1)
                }

            HStack {
                Button("返回重选窗口") {
                    runtime.setupStep = .window
                    Task { await runtime.refreshWindows() }
                }
                .buttonStyle(SecondaryActionButtonStyle())
                Spacer()
                Button {
                    Task { await runtime.confirmCalibration() }
                } label: {
                    Label("确认标定并识别局面", systemImage: "viewfinder.circle.fill")
                }
                .buttonStyle(CockpitActionButtonStyle(color: CockpitPalette.cyan))
                .disabled(runtime.latestImage == nil)
            }
        }
        .padding(22)
    }
}

private struct PositionSetupStep: View {
    @ObservedObject var runtime: PilotRuntime
    @State private var editorSide: XiangqiSide = .red
    @State private var editorGlyph = "炮"
    @State private var eraseMode = false

    private let redGlyphs = ["帥", "仕", "相", "馬", "車", "炮", "兵"]
    private let blackGlyphs = ["將", "士", "象", "馬", "車", "砲", "卒"]

    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("确认任意局面")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(CockpitPalette.primaryText)
                    Spacer()
                    CapsuleBadge(
                        title: runtime.positionIsTrusted ? "可信局面" : "等待确认",
                        color: runtime.positionIsTrusted ? CockpitPalette.green : CockpitPalette.amber,
                        symbolName: runtime.positionIsTrusted ? "checkmark.seal.fill" : "hand.raised.fill"
                    )
                }

                XiangqiBoardView(
                    pieces: runtime.presentation.pieces,
                    proposal: nil,
                    showsRecognitionOverlay: false,
                    onIntersectionTap: { coordinate in
                        runtime.editPiece(
                            at: coordinate,
                            side: eraseMode ? nil : editorSide,
                            glyph: eraseMode ? nil : editorGlyph
                        )
                    }
                )
                .padding(10)
                .background(Color.black.opacity(0.25))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(CockpitPalette.borderStrong, lineWidth: 1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 13) {
                SectionLabel(title: "局面信息")
                Picker("棋盘朝向", selection: $runtime.orientation) {
                    ForEach(BoardOrientation.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                Picker("下一手", selection: $runtime.sideToMove) {
                    Text("红方走").tag(Side.red)
                    Text("黑方走").tag(Side.black)
                }
                .pickerStyle(.segmented)

                KeyValueRow(key: "已识别", value: "\(runtime.presentation.pieces.count) 枚")
                KeyValueRow(
                    key: "置信度",
                    value: runtime.presentation.confidenceText,
                    valueColor: runtime.presentation.confidence >= 0.985 ? CockpitPalette.green : CockpitPalette.amber
                )

                Divider().overlay(CockpitPalette.border)
                SectionLabel(title: "人工校正", detail: "点击棋盘交点")
                Picker("棋子颜色", selection: $editorSide) {
                    Text("红方").tag(XiangqiSide.red)
                    Text("黑方").tag(XiangqiSide.black)
                }
                .pickerStyle(.segmented)
                .onChange(of: editorSide) { _, side in
                    editorGlyph = side == .red ? "炮" : "砲"
                    eraseMode = false
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(editorSide == .red ? redGlyphs : blackGlyphs, id: \.self) { glyph in
                        Button {
                            editorGlyph = glyph
                            eraseMode = false
                        } label: {
                            Text(glyph)
                                .font(.system(size: 16, weight: .bold, design: .serif))
                                .frame(maxWidth: .infinity, minHeight: 34)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(editorSide == .red ? CockpitPalette.red : CockpitPalette.primaryText)
                        .background(editorGlyph == glyph && !eraseMode ? CockpitPalette.cyan.opacity(0.13) : Color.white.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }

                Button {
                    eraseMode = true
                } label: {
                    Label("擦除棋子", systemImage: "eraser.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryActionButtonStyle())

                if !runtime.recognitionWarnings.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(runtime.recognitionWarnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                        }
                    }
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(CockpitPalette.amber)
                }

                Spacer()

                HStack(spacing: 8) {
                    Button("标准开局") {
                        Task { await runtime.useStandardPositionForCorrection() }
                    }
                    .buttonStyle(SecondaryActionButtonStyle(compact: true))
                    Button("恢复上次棋局") {
                        Task { await runtime.restoreLatestSessionForCorrection() }
                    }
                    .buttonStyle(SecondaryActionButtonStyle(compact: true))
                    Button("重新识别") {
                        Task { await runtime.recognizeCurrentPosition() }
                    }
                    .buttonStyle(SecondaryActionButtonStyle(compact: true))
                }

                Button {
                    Task { await runtime.commitManualPosition() }
                } label: {
                    Label("应用为可信局面", systemImage: "checkmark.seal.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(CockpitActionButtonStyle(color: CockpitPalette.green))

                Button {
                    Task { await runtime.completeSetup() }
                } label: {
                    Label("进入象棋驾驶舱", systemImage: "arrow.right.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(CockpitActionButtonStyle(color: CockpitPalette.cyan))
                .disabled(!runtime.positionIsTrusted)
                .opacity(runtime.positionIsTrusted ? 1 : 0.45)
            }
            .padding(14)
            .frame(width: 300)
            .frame(maxHeight: .infinity)
            .cockpitPanel(cornerRadius: 14, raised: true)
        }
        .padding(20)
    }
}
