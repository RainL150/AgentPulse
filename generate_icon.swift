#!/usr/bin/swift

import Cocoa
import CoreGraphics

// 创建 AgentPulse 应用图标
func generateAppIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))

    image.lockFocus()

    guard let context = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let cornerRadius = size * 0.22

    // 背景渐变
    let gradientColors = [
        CGColor(red: 99/255, green: 102/255, blue: 241/255, alpha: 1.0),   // #6366F1
        CGColor(red: 139/255, green: 92/255, blue: 246/255, alpha: 1.0),   // #8B5CF6
        CGColor(red: 236/255, green: 72/255, blue: 153/255, alpha: 1.0)    // #EC4899
    ]
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: gradientColors as CFArray,
        locations: [0.0, 0.5, 1.0]
    )!

    // 圆角矩形路径
    let path = CGPath(roundedRect: rect.insetBy(dx: 2, dy: 2), cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    context.addPath(path)
    context.clip()

    // 绘制渐变背景
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: size),
        end: CGPoint(x: size, y: 0),
        options: []
    )

    // 添加内部光效
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.1))
    let innerGlowPath = CGPath(
        roundedRect: CGRect(x: size * 0.1, y: size * 0.5, width: size * 0.8, height: size * 0.45),
        cornerWidth: size * 0.15,
        cornerHeight: size * 0.15,
        transform: nil
    )
    context.addPath(innerGlowPath)
    context.fillPath()

    // 绘制 CPU 芯片图标
    let centerX = size / 2
    let centerY = size / 2
    let chipSize = size * 0.38
    let pinLength = size * 0.08
    let pinWidth = size * 0.03

    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
    context.setLineWidth(size * 0.025)
    context.setLineCap(.round)

    // 主芯片方块
    let chipRect = CGRect(
        x: centerX - chipSize/2,
        y: centerY - chipSize/2,
        width: chipSize,
        height: chipSize
    )
    let chipPath = CGPath(roundedRect: chipRect, cornerWidth: size * 0.04, cornerHeight: size * 0.04, transform: nil)
    context.addPath(chipPath)
    context.strokePath()

    // 内部电路
    let innerSize = chipSize * 0.5
    let innerRect = CGRect(
        x: centerX - innerSize/2,
        y: centerY - innerSize/2,
        width: innerSize,
        height: innerSize
    )
    let innerPath = CGPath(roundedRect: innerRect, cornerWidth: size * 0.02, cornerHeight: size * 0.02, transform: nil)
    context.addPath(innerPath)
    context.strokePath()

    // 绘制引脚 - 上下左右各3个
    let pinOffset = chipSize * 0.25

    // 上边引脚
    for i in -1...1 {
        let x = centerX + CGFloat(i) * pinOffset
        context.move(to: CGPoint(x: x, y: centerY + chipSize/2))
        context.addLine(to: CGPoint(x: x, y: centerY + chipSize/2 + pinLength))
        context.strokePath()
    }

    // 下边引脚
    for i in -1...1 {
        let x = centerX + CGFloat(i) * pinOffset
        context.move(to: CGPoint(x: x, y: centerY - chipSize/2))
        context.addLine(to: CGPoint(x: x, y: centerY - chipSize/2 - pinLength))
        context.strokePath()
    }

    // 左边引脚
    for i in -1...1 {
        let y = centerY + CGFloat(i) * pinOffset
        context.move(to: CGPoint(x: centerX - chipSize/2, y: y))
        context.addLine(to: CGPoint(x: centerX - chipSize/2 - pinLength, y: y))
        context.strokePath()
    }

    // 右边引脚
    for i in -1...1 {
        let y = centerY + CGFloat(i) * pinOffset
        context.move(to: CGPoint(x: centerX + chipSize/2, y: y))
        context.addLine(to: CGPoint(x: centerX + chipSize/2 + pinLength, y: y))
        context.strokePath()
    }

    // 中心脉冲点
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    let pulseSize = size * 0.08
    let pulsePath = CGPath(
        ellipseIn: CGRect(x: centerX - pulseSize/2, y: centerY - pulseSize/2, width: pulseSize, height: pulseSize),
        transform: nil
    )
    context.addPath(pulsePath)
    context.fillPath()

    // 添加脉冲波纹效果
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.5))
    context.setLineWidth(size * 0.015)
    let wave1 = CGPath(
        ellipseIn: CGRect(x: centerX - pulseSize, y: centerY - pulseSize, width: pulseSize * 2, height: pulseSize * 2),
        transform: nil
    )
    context.addPath(wave1)
    context.strokePath()

    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.25))
    let wave2 = CGPath(
        ellipseIn: CGRect(x: centerX - pulseSize * 1.5, y: centerY - pulseSize * 1.5, width: pulseSize * 3, height: pulseSize * 3),
        transform: nil
    )
    context.addPath(wave2)
    context.strokePath()

    image.unlockFocus()
    return image
}

// 保存图标为 PNG
func saveIcon(_ image: NSImage, to path: String) {
    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:]) else {
        print("Failed to create PNG data")
        return
    }

    do {
        try pngData.write(to: URL(fileURLWithPath: path))
        print("Saved: \(path)")
    } catch {
        print("Failed to save: \(error)")
    }
}

// 生成不同尺寸的图标
let sizes: [(CGFloat, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

let outputDir = "/Users/rainless/Desktop/project/AgentPulse/Resources/AppIcon.iconset"

// 创建输出目录
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

// 生成所有尺寸
for (size, filename) in sizes {
    let icon = generateAppIcon(size: size)
    saveIcon(icon, to: "\(outputDir)/\(filename)")
}

print("\nIcon generation complete!")
print("Run: iconutil -c icns \(outputDir)")
