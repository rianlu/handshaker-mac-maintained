#!/bin/bash

APP_TEMPLATE_DIR="App_Template"
BUILD_DIR="build"
DMG_ASSETS_DIR="assets/dmg"

# 1. 准备空壳
echo "🚀 开始组装 HandShaker.app..."
rm -rf "${BUILD_DIR}/HandShaker.app"
mkdir -p "${BUILD_DIR}/HandShaker.app"

# 2. 注入灵魂
cp -R "${APP_TEMPLATE_DIR}/Contents" "${BUILD_DIR}/HandShaker.app/"

# 3. 重新签名
echo "🔐 正在进行本地重签名..."
codesign --force --deep --sign - "${BUILD_DIR}/HandShaker.app"

# 4. 像素级完全复刻打包模式
echo "📦 正在生成工业级 DMG 安装包..."

create-dmg \
  --volname "HandShaker" \
  --background "${DMG_ASSETS_DIR}/backgroundImage@2x.jpg" \
  --volicon "${DMG_ASSETS_DIR}/Volume.icns" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "HandShaker.app" 150 190 \
  --hide-extension "HandShaker.app" \
  --app-drop-link 450 190 \
  --icon ".background" 150 550 \
  --icon ".VolumeIcon.icns" 450 550 \
  "${BUILD_DIR}/HandShaker-Mac-Maintained-v2.5.6.dmg" \
  "${BUILD_DIR}/"

echo "✅ 像素级完全复刻打包完成！"
