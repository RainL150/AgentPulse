#!/bin/bash
# AgentPulse 构建脚本

set -e

echo "🔨 Building AgentPulse..."

cd "$(dirname "$0")"

# 使用 Swift Package Manager 构建
swift build -c release

# 复制到 Applications
APP_NAME="AgentPulse"
BUILD_DIR=".build/release"
DEST="/Applications/$APP_NAME.app"

echo "📦 Creating app bundle..."

# 创建 app bundle 结构
mkdir -p "$DEST/Contents/MacOS"
mkdir -p "$DEST/Contents/Resources"

# 复制可执行文件
cp "$BUILD_DIR/$APP_NAME" "$DEST/Contents/MacOS/"

# 复制 Info.plist
cp "Sources/Info.plist" "$DEST/Contents/"

# 创建 PkgInfo
echo -n "APPL????" > "$DEST/Contents/PkgInfo"

echo "✅ Built successfully!"
echo ""
echo "📍 App location: $DEST"
echo ""
echo "🚀 To run:"
echo "   open /Applications/AgentPulse.app"
echo ""
echo "💡 Or run directly:"
echo "   $BUILD_DIR/$APP_NAME"
