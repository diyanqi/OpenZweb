import SwiftUI

struct SparklineView: View {
    let downs: [Double]
    let ups: [Double]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let maxV = max(downs.max() ?? 0, ups.max() ?? 0, 1)

            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.04))

                path(for: downs, width: w, height: h, maxV: maxV)
                    .stroke(Color.accentColor.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                path(for: ups, width: w, height: h, maxV: maxV)
                    .stroke(Color.orange.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func path(for values: [Double], width: CGFloat, height: CGFloat, maxV: Double) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        let step = width / CGFloat(max(values.count - 1, 1))
        for (i, v) in values.enumerated() {
            let x = CGFloat(i) * step
            let y = height - CGFloat(v / maxV) * (height - 8) - 4
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }
}
