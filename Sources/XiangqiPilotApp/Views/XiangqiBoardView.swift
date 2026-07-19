import SwiftUI

private struct BoardGeometry {
    let origin: CGPoint
    let cell: CGFloat

    init(size: CGSize, inset: CGFloat = 28) {
        let usableWidth = max(size.width - inset * 2, 0)
        let usableHeight = max(size.height - inset * 2, 0)
        cell = max(min(usableWidth / 8, usableHeight / 9), 1)
        let width = cell * 8
        let height = cell * 9
        origin = CGPoint(x: (size.width - width) / 2, y: (size.height - height) / 2)
    }

    func point(for coordinate: BoardCoordinate) -> CGPoint {
        CGPoint(
            x: origin.x + CGFloat(coordinate.column) * cell,
            y: origin.y + CGFloat(coordinate.row) * cell
        )
    }

    var rect: CGRect {
        CGRect(x: origin.x, y: origin.y, width: cell * 8, height: cell * 9)
    }
}

struct XiangqiBoardView: View {
    let pieces: [BoardPiece]
    var proposal: CandidateMove?
    var showsRecognitionOverlay: Bool = true
    var compact: Bool = false
    var onIntersectionTap: ((BoardCoordinate) -> Void)? = nil

    var body: some View {
        GeometryReader { proxy in
            let geometry = BoardGeometry(size: proxy.size, inset: compact ? 19 : 32)

            ZStack {
                boardSurface(geometry: geometry, size: proxy.size)

                ForEach(pieces) { piece in
                    XiangqiPieceView(piece: piece, diameter: min(geometry.cell * 0.78, compact ? 32 : 45))
                        .position(geometry.point(for: piece.coordinate))
                }

                if let proposal {
                    proposalOverlay(proposal, geometry: geometry, size: proxy.size)
                }

                if showsRecognitionOverlay {
                    recognitionCorners(geometry: geometry)
                }

                if let onIntersectionTap {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            SpatialTapGesture()
                                .onEnded { value in
                                    let file = Int(((value.location.x - geometry.origin.x) / geometry.cell).rounded())
                                    let rank = Int(((value.location.y - geometry.origin.y) / geometry.cell).rounded())
                                    guard (0...8).contains(file), (0...9).contains(rank) else { return }
                                    let coordinate = BoardCoordinate(column: file, row: rank)
                                    let target = geometry.point(for: coordinate)
                                    guard hypot(value.location.x - target.x, value.location.y - target.y) <= geometry.cell * 0.48 else { return }
                                    onIntersectionTap(coordinate)
                                }
                        )
                }
            }
        }
        .aspectRatio(0.92, contentMode: .fit)
    }

    private func boardSurface(geometry: BoardGeometry, size: CGSize) -> some View {
        Canvas { context, _ in
            let outerRect = geometry.rect.insetBy(dx: -geometry.cell * 0.5, dy: -geometry.cell * 0.5)
            let rounded = Path(roundedRect: outerRect, cornerRadius: max(geometry.cell * 0.16, 6))

            context.fill(
                rounded,
                with: .linearGradient(
                    Gradient(colors: [CockpitPalette.boardHighlight, CockpitPalette.boardSurface]),
                    startPoint: CGPoint(x: outerRect.minX, y: outerRect.minY),
                    endPoint: CGPoint(x: outerRect.maxX, y: outerRect.maxY)
                )
            )

            context.stroke(
                rounded,
                with: .color(CockpitPalette.boardLine.opacity(0.45)),
                lineWidth: max(geometry.cell * 0.035, 1)
            )

            var horizontalLines = Path()
            for row in 0...9 {
                let y = geometry.origin.y + CGFloat(row) * geometry.cell
                horizontalLines.move(to: CGPoint(x: geometry.origin.x, y: y))
                horizontalLines.addLine(to: CGPoint(x: geometry.origin.x + 8 * geometry.cell, y: y))
            }
            context.stroke(horizontalLines, with: .color(CockpitPalette.boardLine.opacity(0.82)), lineWidth: 1)

            var verticalLines = Path()
            for column in 0...8 {
                let x = geometry.origin.x + CGFloat(column) * geometry.cell
                if column == 0 || column == 8 {
                    verticalLines.move(to: CGPoint(x: x, y: geometry.origin.y))
                    verticalLines.addLine(to: CGPoint(x: x, y: geometry.origin.y + 9 * geometry.cell))
                } else {
                    verticalLines.move(to: CGPoint(x: x, y: geometry.origin.y))
                    verticalLines.addLine(to: CGPoint(x: x, y: geometry.origin.y + 4 * geometry.cell))
                    verticalLines.move(to: CGPoint(x: x, y: geometry.origin.y + 5 * geometry.cell))
                    verticalLines.addLine(to: CGPoint(x: x, y: geometry.origin.y + 9 * geometry.cell))
                }
            }
            context.stroke(verticalLines, with: .color(CockpitPalette.boardLine.opacity(0.82)), lineWidth: 1)

            var palace = Path()
            palace.move(to: geometry.point(for: BoardCoordinate(column: 3, row: 0)))
            palace.addLine(to: geometry.point(for: BoardCoordinate(column: 5, row: 2)))
            palace.move(to: geometry.point(for: BoardCoordinate(column: 5, row: 0)))
            palace.addLine(to: geometry.point(for: BoardCoordinate(column: 3, row: 2)))
            palace.move(to: geometry.point(for: BoardCoordinate(column: 3, row: 7)))
            palace.addLine(to: geometry.point(for: BoardCoordinate(column: 5, row: 9)))
            palace.move(to: geometry.point(for: BoardCoordinate(column: 5, row: 7)))
            palace.addLine(to: geometry.point(for: BoardCoordinate(column: 3, row: 9)))
            context.stroke(palace, with: .color(CockpitPalette.boardLine.opacity(0.78)), lineWidth: 1)

            let riverY = geometry.origin.y + geometry.cell * 4.5
            let riverFont = Font.system(size: max(geometry.cell * 0.27, 10), weight: .semibold, design: .serif)
            context.draw(
                Text("楚  河")
                    .font(riverFont)
                    .foregroundColor(CockpitPalette.boardLine.opacity(0.72)),
                at: CGPoint(x: geometry.origin.x + geometry.cell * 2, y: riverY)
            )
            context.draw(
                Text("漢  界")
                    .font(riverFont)
                    .foregroundColor(CockpitPalette.boardLine.opacity(0.72)),
                at: CGPoint(x: geometry.origin.x + geometry.cell * 6, y: riverY)
            )

            drawPositionMarks(context: &context, geometry: geometry)
        }
        .frame(width: size.width, height: size.height)
        .shadow(color: Color.black.opacity(0.28), radius: 18, y: 10)
    }

    private func drawPositionMarks(context: inout GraphicsContext, geometry: BoardGeometry) {
        let coordinates = [
            BoardCoordinate(column: 1, row: 2), BoardCoordinate(column: 7, row: 2),
            BoardCoordinate(column: 0, row: 3), BoardCoordinate(column: 2, row: 3),
            BoardCoordinate(column: 4, row: 3), BoardCoordinate(column: 6, row: 3),
            BoardCoordinate(column: 8, row: 3), BoardCoordinate(column: 0, row: 6),
            BoardCoordinate(column: 2, row: 6), BoardCoordinate(column: 4, row: 6),
            BoardCoordinate(column: 6, row: 6), BoardCoordinate(column: 8, row: 6),
            BoardCoordinate(column: 1, row: 7), BoardCoordinate(column: 7, row: 7)
        ]

        let arm = max(geometry.cell * 0.1, 3)
        let gap = max(geometry.cell * 0.07, 2)
        var marks = Path()

        for coordinate in coordinates {
            let point = geometry.point(for: coordinate)
            let canDrawLeft = coordinate.column > 0
            let canDrawRight = coordinate.column < 8

            if canDrawLeft {
                marks.move(to: CGPoint(x: point.x - gap, y: point.y - gap - arm))
                marks.addLine(to: CGPoint(x: point.x - gap, y: point.y - gap))
                marks.addLine(to: CGPoint(x: point.x - gap - arm, y: point.y - gap))
                marks.move(to: CGPoint(x: point.x - gap, y: point.y + gap + arm))
                marks.addLine(to: CGPoint(x: point.x - gap, y: point.y + gap))
                marks.addLine(to: CGPoint(x: point.x - gap - arm, y: point.y + gap))
            }

            if canDrawRight {
                marks.move(to: CGPoint(x: point.x + gap, y: point.y - gap - arm))
                marks.addLine(to: CGPoint(x: point.x + gap, y: point.y - gap))
                marks.addLine(to: CGPoint(x: point.x + gap + arm, y: point.y - gap))
                marks.move(to: CGPoint(x: point.x + gap, y: point.y + gap + arm))
                marks.addLine(to: CGPoint(x: point.x + gap, y: point.y + gap))
                marks.addLine(to: CGPoint(x: point.x + gap + arm, y: point.y + gap))
            }
        }

        context.stroke(marks, with: .color(CockpitPalette.boardLine.opacity(0.7)), lineWidth: 1)
    }

    private func proposalOverlay(
        _ proposal: CandidateMove,
        geometry: BoardGeometry,
        size: CGSize
    ) -> some View {
        Canvas { context, _ in
            let origin = geometry.point(for: proposal.origin)
            let target = geometry.point(for: proposal.target)

            var line = Path()
            line.move(to: origin)
            line.addLine(to: target)
            context.stroke(
                line,
                with: .color(CockpitPalette.cyan),
                style: StrokeStyle(lineWidth: max(geometry.cell * 0.07, 2), lineCap: .round, dash: [8, 6])
            )

            let targetRadius = geometry.cell * 0.36
            let targetRect = CGRect(
                x: target.x - targetRadius,
                y: target.y - targetRadius,
                width: targetRadius * 2,
                height: targetRadius * 2
            )
            context.fill(Path(ellipseIn: targetRect), with: .color(CockpitPalette.cyan.opacity(0.16)))
            context.stroke(Path(ellipseIn: targetRect), with: .color(CockpitPalette.cyan), lineWidth: 2.5)

            let originRadius = geometry.cell * 0.43
            let originRect = CGRect(
                x: origin.x - originRadius,
                y: origin.y - originRadius,
                width: originRadius * 2,
                height: originRadius * 2
            )
            context.stroke(Path(ellipseIn: originRect), with: .color(CockpitPalette.cyan.opacity(0.55)), lineWidth: 1.5)
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    private func recognitionCorners(geometry: BoardGeometry) -> some View {
        Canvas { context, _ in
            let rect = geometry.rect.insetBy(dx: -geometry.cell * 0.62, dy: -geometry.cell * 0.62)
            let arm = max(geometry.cell * 0.38, 14)
            var corners = Path()

            corners.move(to: CGPoint(x: rect.minX, y: rect.minY + arm))
            corners.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            corners.addLine(to: CGPoint(x: rect.minX + arm, y: rect.minY))

            corners.move(to: CGPoint(x: rect.maxX - arm, y: rect.minY))
            corners.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            corners.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + arm))

            corners.move(to: CGPoint(x: rect.minX, y: rect.maxY - arm))
            corners.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            corners.addLine(to: CGPoint(x: rect.minX + arm, y: rect.maxY))

            corners.move(to: CGPoint(x: rect.maxX - arm, y: rect.maxY))
            corners.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            corners.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - arm))

            context.stroke(corners, with: .color(CockpitPalette.cyan.opacity(0.8)), lineWidth: 2)
        }
        .allowsHitTesting(false)
    }
}

private struct XiangqiPieceView: View {
    let piece: BoardPiece
    let diameter: CGFloat

    private var ink: Color {
        piece.side == .red ? Color(red: 0.73, green: 0.12, blue: 0.10) : Color(red: 0.10, green: 0.105, blue: 0.11)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(red: 0.96, green: 0.83, blue: 0.61), Color(red: 0.79, green: 0.62, blue: 0.39)],
                        center: .topLeading,
                        startRadius: 2,
                        endRadius: diameter * 0.65
                    )
                )
            Circle()
                .stroke(ink.opacity(0.9), lineWidth: max(diameter * 0.055, 1.4))
                .padding(diameter * 0.08)
            Circle()
                .stroke(ink.opacity(0.42), lineWidth: 1)
                .padding(diameter * 0.16)
            Text(piece.character)
                .font(.system(size: diameter * 0.47, weight: .bold, design: .serif))
                .foregroundStyle(ink)
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: Color.black.opacity(0.36), radius: max(diameter * 0.08, 2), y: max(diameter * 0.06, 1))
    }
}
