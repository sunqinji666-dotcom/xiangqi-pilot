import AppKit
import SwiftUI

struct CalibrationCanvas: View {
    let image: NSImage?
    @Binding var corners: NormalizedBoardCorners

    var body: some View {
        GeometryReader { proxy in
            if let image {
                let rect = fittedRect(imageSize: image.size, container: proxy.size)
                ZStack {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: proxy.size.width, height: proxy.size.height)

                    gridOverlay(in: rect)
                    handle("1", point: binding(\.topLeft), in: rect)
                    handle("2", point: binding(\.topRight), in: rect)
                    handle("3", point: binding(\.bottomRight), in: rect)
                    handle("4", point: binding(\.bottomLeft), in: rect)
                }
                .coordinateSpace(name: "calibration-canvas")
            } else {
                ProgressView("等待窗口画面…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func gridOverlay(in rect: CGRect) -> some View {
        Canvas { context, _ in
            var path = Path()
            for file in 0..<9 {
                let u = CGFloat(file) / 8
                path.move(to: interpolate(corners.topLeft, corners.topRight, u, rect))
                path.addLine(to: interpolate(corners.bottomLeft, corners.bottomRight, u, rect))
            }
            for rank in 0..<10 {
                let v = CGFloat(rank) / 9
                path.move(to: interpolate(corners.topLeft, corners.bottomLeft, v, rect))
                path.addLine(to: interpolate(corners.topRight, corners.bottomRight, v, rect))
            }
            context.stroke(path, with: .color(CockpitPalette.cyan.opacity(0.78)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }

    private func handle(_ label: String, point: Binding<CGPoint>, in rect: CGRect) -> some View {
        ZStack {
            Circle().fill(CockpitPalette.cyan)
            Circle().stroke(Color.white.opacity(0.9), lineWidth: 2)
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.black)
        }
        .frame(width: 27, height: 27)
        .shadow(color: CockpitPalette.cyan.opacity(0.45), radius: 8)
        .position(displayPoint(point.wrappedValue, in: rect))
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("calibration-canvas"))
                .onChanged { value in
                    point.wrappedValue = normalizedPoint(value.location, in: rect)
                }
        )
    }

    private func binding(_ keyPath: WritableKeyPath<NormalizedBoardCorners, CGPoint>) -> Binding<CGPoint> {
        Binding(
            get: { corners[keyPath: keyPath] },
            set: { value in corners[keyPath: keyPath] = value }
        )
    }

    private func fittedRect(imageSize: CGSize, container: CGSize) -> CGRect {
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (container.width - size.width) / 2,
                      y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    private func displayPoint(_ normalized: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + normalized.x * rect.width,
                y: rect.minY + normalized.y * rect.height)
    }

    private func normalizedPoint(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: min(1, max(0, (point.x - rect.minX) / rect.width)),
                y: min(1, max(0, (point.y - rect.minY) / rect.height)))
    }

    private func interpolate(_ a: CGPoint, _ b: CGPoint, _ fraction: CGFloat, _ rect: CGRect) -> CGPoint {
        let point = CGPoint(x: a.x + (b.x - a.x) * fraction,
                            y: a.y + (b.y - a.y) * fraction)
        return displayPoint(point, in: rect)
    }
}
