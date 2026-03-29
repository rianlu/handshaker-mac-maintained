#!/bin/bash

APP_TEMPLATE_DIR="App_Template"
BUILD_DIR="build"
DMG_ASSETS_DIR="assets/dmg"
RELEASE_CONFIG_FILE="./release.conf"

fail() {
  printf '%s\n' "FAIL: $1" >&2
  exit 1
}

require_file() {
  [ -f "$1" ] || fail "missing required file: $1"
}

detect_release_arch() {
  local executable_path="${APP_TEMPLATE_DIR}/Contents/MacOS/HandShaker"
  local archs

  require_file "${executable_path}"
  archs="$(lipo -archs "${executable_path}" 2>/dev/null)" || fail "failed to read binary architecture: ${executable_path}"

  case "${archs}" in
    "x86_64 arm64"|"arm64 x86_64")
      RELEASE_ARCH_NAME="universal"
      ;;
    *)
      RELEASE_ARCH_NAME="${archs// /-}"
      ;;
  esac

  [ -n "${RELEASE_ARCH_NAME}" ] || fail "resolved empty architecture name"
}

load_release_config() {
  require_file "${RELEASE_CONFIG_FILE}"
  # shellcheck disable=SC1090
  . "${RELEASE_CONFIG_FILE}"

  : "${RELEASE_BASE_VERSION:?missing RELEASE_BASE_VERSION in ${RELEASE_CONFIG_FILE}}"
  : "${RELEASE_BUILD_NUMBER:?missing RELEASE_BUILD_NUMBER in ${RELEASE_CONFIG_FILE}}"

  case "${RELEASE_BUILD_NUMBER}" in
    ''|*[!0-9]*)
      fail "RELEASE_BUILD_NUMBER must be numeric: ${RELEASE_BUILD_NUMBER}"
      ;;
  esac

  if [ -n "${RELEASE_SUFFIX:-}" ]; then
    RELEASE_VERSION_NAME="${RELEASE_BASE_VERSION}-${RELEASE_SUFFIX}"
  else
    RELEASE_VERSION_NAME="${RELEASE_BASE_VERSION}"
  fi

  detect_release_arch
  RELEASE_DMG_NAME="handshaker-mac-maintained-${RELEASE_VERSION_NAME}-${RELEASE_ARCH_NAME}.dmg"
}

apply_release_version() {
  local info_plist="${BUILD_DIR}/HandShaker.app/Contents/Info.plist"

  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${RELEASE_VERSION_NAME}" "${info_plist}"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${RELEASE_BUILD_NUMBER}" "${info_plist}"
}

load_release_config

# 1. 准备空壳
echo "🚀 开始组装 HandShaker.app..."
rm -rf "${BUILD_DIR}/HandShaker.app"
mkdir -p "${BUILD_DIR}/HandShaker.app"

# 2. 注入灵魂
cp -R "${APP_TEMPLATE_DIR}/Contents" "${BUILD_DIR}/HandShaker.app/"

# 2.1 注入版本信息
echo "🏷️ 正在应用维护版版本号..."
apply_release_version

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
  "${BUILD_DIR}/${RELEASE_DMG_NAME}" \
  "${BUILD_DIR}/"

echo "版本号: ${RELEASE_VERSION_NAME} (${RELEASE_BUILD_NUMBER})"
echo "架构: ${RELEASE_ARCH_NAME}"
echo "DMG: ${BUILD_DIR}/${RELEASE_DMG_NAME}"
echo "✅ 像素级完全复刻打包完成！"
