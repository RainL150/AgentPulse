import SwiftUI

/// 脉冲图标视图
struct PulseIconView: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            // 渐变背景
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: "6366F1"), Color(hex: "06B6D4")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)

            // 脉冲线
            PulseShape()
                .stroke(Color.white, style: StrokeStyle(lineWidth: size * 0.06, lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.7, height: size * 0.5)

            // 发光点
            Circle()
                .fill(Color.white)
                .frame(width: size * 0.12, height: size * 0.12)
                .shadow(color: .white.opacity(0.8), radius: size * 0.08)
                .offset(x: -size * 0.035, y: -size * 0.25)
        }
    }
}

/// 脉冲波形
struct PulseShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        let midY = rect.midY

        // 心电图波形
        path.move(to: CGPoint(x: 0, y: midY))
        path.addLine(to: CGPoint(x: w * 0.25, y: midY))
        path.addLine(to: CGPoint(x: w * 0.32, y: midY - h * 0.15))
        path.addLine(to: CGPoint(x: w * 0.38, y: midY + h * 0.08))
        path.addLine(to: CGPoint(x: w * 0.45, y: midY - h * 0.5))  // 主峰
        path.addLine(to: CGPoint(x: w * 0.52, y: midY + h * 0.3))
        path.addLine(to: CGPoint(x: w * 0.58, y: midY - h * 0.1))
        path.addLine(to: CGPoint(x: w * 0.65, y: midY))
        path.addLine(to: CGPoint(x: w, y: midY))

        return path
    }
}
