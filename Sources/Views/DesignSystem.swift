import SwiftUI

// MARK: - 设计系统

/// 颜色主题
enum Theme {
    // 主色调
    static let primary = Color(hex: "6366F1")      // 靛蓝
    static let secondary = Color(hex: "8B5CF6")    // 紫色
    static let accent = Color(hex: "06B6D4")       // 青色

    // 状态颜色
    static let success = Color(hex: "10B981")      // 绿色
    static let warning = Color(hex: "F59E0B")      // 橙色
    static let error = Color(hex: "EF4444")        // 红色
    static let info = Color(hex: "3B82F6")         // 蓝色

    // 背景颜色
    static let bgPrimary = Color(hex: "0F0F14")
    static let bgSecondary = Color(hex: "1A1A24")
    static let bgTertiary = Color(hex: "252532")
    static let bgElevated = Color(hex: "2A2A3C")

    // 文字颜色
    static let textPrimary = Color.white.opacity(0.95)
    static let textSecondary = Color.white.opacity(0.7)
    static let textTertiary = Color.white.opacity(0.5)
    static let textMuted = Color.white.opacity(0.35)

    // 渐变
    static let gradientPrimary = LinearGradient(
        colors: [Color(hex: "6366F1"), Color(hex: "8B5CF6")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let gradientSuccess = LinearGradient(
        colors: [Color(hex: "10B981"), Color(hex: "059669")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let gradientWarning = LinearGradient(
        colors: [Color(hex: "F59E0B"), Color(hex: "D97706")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let gradientError = LinearGradient(
        colors: [Color(hex: "EF4444"), Color(hex: "DC2626")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let gradientGlass = LinearGradient(
        colors: [Color.white.opacity(0.12), Color.white.opacity(0.05)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - 玻璃效果背景

struct GlassBackground: View {
    var cornerRadius: CGFloat = 20
    var opacity: Double = 0.85

    var body: some View {
        ZStack {
            // 主背景
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Theme.bgPrimary.opacity(opacity))

            // 边框高光
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.15),
                            Color.white.opacity(0.05),
                            Color.white.opacity(0.02)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )

            // 内部光晕
            RoundedRectangle(cornerRadius: cornerRadius - 1, style: .continuous)
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.08),
                            Color.clear
                        ],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: 300
                    )
                )
                .padding(1)
        }
    }
}

// MARK: - 卡片样式

struct GlassCard<Content: View>: View {
    let content: Content
    var padding: CGFloat = 12
    var cornerRadius: CGFloat = 16

    init(padding: CGFloat = 12, cornerRadius: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.padding = padding
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        content
            .padding(padding)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Theme.bgSecondary.opacity(0.6))

                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                }
            )
    }
}

// MARK: - 状态指示器

struct StatusDot: View {
    let color: Color
    var size: CGFloat = 8
    var animated: Bool = false

    @State private var isAnimating = false

    var body: some View {
        ZStack {
            // 光晕效果
            if animated {
                Circle()
                    .fill(color.opacity(0.4))
                    .frame(width: size * 2, height: size * 2)
                    .scaleEffect(isAnimating ? 1.5 : 1.0)
                    .opacity(isAnimating ? 0 : 0.6)
            }

            // 主圆点
            Circle()
                .fill(color)
                .frame(width: size, height: size)

            // 高光
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.6), Color.clear],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: size * 0.6
                    )
                )
                .frame(width: size, height: size)
        }
        .onAppear {
            if animated {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) {
                    isAnimating = true
                }
            }
        }
    }
}

// MARK: - 渐变按钮

struct GradientButton: View {
    let title: String
    let icon: String?
    let gradient: LinearGradient
    let action: () -> Void

    init(_ title: String, icon: String? = nil, gradient: LinearGradient = Theme.gradientPrimary, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.gradient = gradient
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(gradient)
            .clipShape(Capsule())
            .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 工具图标

struct ToolIcon: View {
    let tool: String
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: iconName)
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundColor(toolColor)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                    .fill(toolColor.opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                    .stroke(toolColor.opacity(0.3), lineWidth: 1)
            )
    }

    private var iconName: String {
        switch tool {
        case "Read": return "doc.text"
        case "Edit": return "pencil"
        case "Write": return "doc.badge.plus"
        case "Bash": return "terminal"
        case "Grep": return "magnifyingglass"
        case "Glob": return "folder.badge.questionmark"
        case "Task": return "person.2"
        case "Skill": return "sparkles.rectangle.stack"
        case "WebSearch": return "globe"
        case "WebFetch": return "arrow.down.doc"
        case "TaskCreate": return "plus.circle"
        case "TaskUpdate": return "checkmark.circle"
        case "AskUserQuestion": return "questionmark.bubble"
        default: return "wrench"
        }
    }

    private var toolColor: Color {
        switch tool {
        case "Read": return Theme.info
        case "Edit", "Write": return Theme.warning
        case "Bash": return Theme.success
        case "Grep", "Glob": return Theme.secondary
        case "WebSearch", "WebFetch": return Theme.accent
        case "TaskCreate", "TaskUpdate": return Color(hex: "EC4899")
        case "Task": return Theme.primary
        case "Skill": return Color(hex: "EAB308")
        case "AskUserQuestion": return Theme.info
        default: return Theme.textSecondary
        }
    }
}

// MARK: - 标签徽章

struct TagBadge: View {
    let text: String
    var color: Color = Theme.primary
    var style: Style = .filled

    enum Style {
        case filled
        case outlined
        case subtle
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(foregroundColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(background)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(borderColor, lineWidth: style == .outlined ? 1 : 0)
            )
    }

    private var foregroundColor: Color {
        switch style {
        case .filled: return .white
        case .outlined: return color
        case .subtle: return color
        }
    }

    private var background: some View {
        Group {
            switch style {
            case .filled:
                Capsule().fill(color)
            case .outlined:
                Capsule().fill(Color.clear)
            case .subtle:
                Capsule().fill(color.opacity(0.15))
            }
        }
    }

    private var borderColor: Color {
        style == .outlined ? color : .clear
    }
}

// MARK: - 分隔线

struct SectionDivider: View {
    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [Color.clear, Color.white.opacity(0.1), Color.clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 1)
    }
}

// MARK: - 动画修饰器

struct ShimmerEffect: ViewModifier {
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0),
                        Color.white.opacity(0.2),
                        Color.white.opacity(0)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .rotationEffect(.degrees(30))
                .offset(x: phase)
                .mask(content)
            )
            .onAppear {
                withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                    phase = 200
                }
            }
    }
}

extension View {
    func shimmer() -> some View {
        modifier(ShimmerEffect())
    }
}

// MARK: - 弹性缩放效果

struct BouncyButton: ViewModifier {
    @State private var isPressed = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed ? 0.95 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isPressed)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in isPressed = true }
                    .onEnded { _ in isPressed = false }
            )
    }
}

extension View {
    func bouncyButton() -> some View {
        modifier(BouncyButton())
    }
}

// MARK: - Token 显示组件

struct TokenDisplay: View {
    let usage: TokenUsage
    var compact: Bool = true

    var body: some View {
        if compact {
            HStack(spacing: 4) {
                Image(systemName: "sparkle")
                    .font(.system(size: 9))
                Text(usage.formatted)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
            }
            .foregroundColor(Theme.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.accent.opacity(0.15))
            .clipShape(Capsule())
        } else {
            HStack(spacing: 12) {
                tokenStat(label: "输入", value: usage.inputFormatted, color: Theme.info)
                tokenStat(label: "输出", value: usage.outputFormatted, color: Theme.success)
                tokenStat(label: "总计", value: usage.formatted, color: Theme.accent)
            }
        }
    }

    private func tokenStat(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(Theme.textMuted)
        }
    }
}
