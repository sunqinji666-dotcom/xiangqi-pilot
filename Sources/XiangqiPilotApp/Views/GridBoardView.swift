import SwiftUI
import XiangqiCore

struct GridBoardView: View {
    let lineCount: Int
    let stones: [GridStonePiece]
    let proposal: CandidateMove

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height) * 0.90
            let origin = CGPoint(x: (proxy.size.width - side) / 2, y: (proxy.size.height - side) / 2)
            let step = side / CGFloat(max(1, lineCount - 1))
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(red: 0.73, green: 0.57, blue: 0.34))
                    .frame(width: side + step * 0.6, height: side + step * 0.6)

                Path { path in
                    for index in 0..<lineCount {
                        let offset = CGFloat(index) * step
                        path.move(to: CGPoint(x: origin.x, y: origin.y + offset))
                        path.addLine(to: CGPoint(x: origin.x + side, y: origin.y + offset))
                        path.move(to: CGPoint(x: origin.x + offset, y: origin.y))
                        path.addLine(to: CGPoint(x: origin.x + offset, y: origin.y + side))
                    }
                }
                .stroke(Color.black.opacity(0.58), lineWidth: max(0.7, step * 0.025))

                ForEach(stones) { stone in
                    stoneView(stone, step: step)
                        .position(point(stone.coordinate, origin: origin, step: step))
                }

                if proposal.id.hasPrefix("grid:"),
                   let coordinate = parse(proposal.id) {
                    Circle()
                        .stroke(CockpitPalette.cyan, lineWidth: max(2, step * 0.10))
                        .frame(width: step * 0.92, height: step * 0.92)
                        .position(point(coordinate, origin: origin, step: step))
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func point(_ coordinate: GridCoordinate, origin: CGPoint, step: CGFloat) -> CGPoint {
        CGPoint(x: origin.x + CGFloat(coordinate.column) * step, y: origin.y + CGFloat(coordinate.row) * step)
    }

    private func stoneView(_ stone: GridStonePiece, step: CGFloat) -> some View {
        let isBlack = stone.side == .black
        return Circle()
            .fill(isBlack ? Color.black : Color.white)
            .overlay(Circle().stroke(Color.black.opacity(isBlack ? 0.24 : 0.38), lineWidth: 1))
            .shadow(color: .black.opacity(0.34), radius: 2, y: 1)
            .frame(width: step * 0.78, height: step * 0.78)
    }

    private func parse(_ id: String) -> GridCoordinate? {
        let components = id.dropFirst(5).split(separator: ",")
        guard components.count == 2, let column = Int(components[0]), let row = Int(components[1]) else { return nil }
        return GridCoordinate(column: column, row: row)
    }
}
