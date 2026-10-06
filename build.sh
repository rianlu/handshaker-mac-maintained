#!/bin/bash

set -eu

APP_TEMPLATE_DIR="App_Template"
BUILD_DIR="${HANDSHAKER_MAC_BUILD_DIR:-build}"
DMG_ASSETS_DIR="assets/dmg"
RELEASE_CONFIG_FILE="./release.conf"
SMARTFINDER_CORE_PATCH_SCRIPT="./patches/build_smartfinder_core_wrapper.sh"
ANDROID_RELEASE_URL="https://github.com/rianlu/handshaker-android-maintained/releases/latest"

fail() {
  printf '%s\n' "FAIL: $1" >&2
  exit 1
}

require_file() {
  [ -f "$1" ] || fail "missing required file: $1"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
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

patch_accessory_download_url() {
  local executable_path="${BUILD_DIR}/HandShaker.app/Contents/Frameworks/SmartFinderCore.framework/Versions/A/SmartFinderCore"

  require_file "${executable_path}"
  EXECUTABLE_PATH="${executable_path}" ANDROID_RELEASE_URL="${ANDROID_RELEASE_URL}" perl <<'PERL' || fail "failed to update Android release URL"
use strict;
use warnings;

my $path = $ENV{EXECUTABLE_PATH};
my $url = $ENV{ANDROID_RELEASE_URL};
my $url_offset = 0x290680;
my $pointer_offset = 0x2b2fa8;
my $length_offset = 0x2b2fb0;
my $legacy_url = 'http://sf.smartisan.com/sf/release/apk';

open my $file, '+<', $path or die "cannot open $path: $!\n";
binmode $file;

seek $file, 0x26bfcb, 0 or die "cannot seek to legacy URL: $!\n";
read $file, my $actual_legacy_url, length($legacy_url) or die "cannot read legacy URL: $!\n";
die "unexpected legacy Android URL\n" unless $actual_legacy_url eq $legacy_url;

seek $file, $url_offset, 0 or die "cannot seek to URL storage: $!\n";
read $file, my $storage, length($url) + 1 or die "cannot read URL storage: $!\n";
die "Android URL storage is not empty\n" unless $storage eq "\0" x (length($url) + 1);
seek $file, $url_offset, 0 or die "cannot seek to URL storage: $!\n";
print {$file} $url, "\0" or die "cannot write Android URL: $!\n";

seek $file, $pointer_offset, 0 or die "cannot seek to URL pointer: $!\n";
read $file, my $pointer, 8 or die "cannot read URL pointer: $!\n";
die "unexpected Android URL pointer\n" unless $pointer eq pack('Q<', 0x26bfcb);
seek $file, $pointer_offset, 0 or die "cannot seek to URL pointer: $!\n";
print {$file} pack('Q<', $url_offset) or die "cannot write URL pointer: $!\n";

seek $file, $length_offset, 0 or die "cannot seek to URL length: $!\n";
read $file, my $length, 8 or die "cannot read URL length: $!\n";
die "unexpected Android URL length\n" unless $length eq pack('Q<', length($legacy_url));
seek $file, $length_offset, 0 or die "cannot seek to URL length: $!\n";
print {$file} pack('Q<', length($url)) or die "cannot write URL length: $!\n";
PERL
}

patch_legacy_nib_button() {
  local nib_path="$1"
  local match_count

  require_file "${nib_path}"
  match_count="$(LC_ALL=C grep -ao 'SFButton' "${nib_path}" | wc -l | tr -d ' ')"
  [ "${match_count}" = "1" ] || fail "unexpected SFButton count in ${nib_path}: ${match_count}"
  LC_ALL=C perl -0pi -e 's/SFButton/HSButton/g' "${nib_path}"
}

restore_photo_sync_prompt() {
  local executable_path="${BUILD_DIR}/HandShaker.app/Contents/MacOS/HandShaker"

  require_file "${executable_path}"
  EXECUTABLE_PATH="${executable_path}" perl <<'PERL' || fail "failed to restore local sync prompt"
use strict;
use warnings;

my $path = $ENV{EXECUTABLE_PATH};
open my $file, '+<', $path or die "cannot open $path: $!\n";
binmode $file;

sub restore_bytes {
  my ($offset, $disabled, $enabled, $label) = @_;
  seek $file, $offset, 0 or die "cannot seek to $label: $!\n";
  read $file, my $actual, length($disabled) == length($enabled) ? length($disabled) : die "invalid $label patch length\n";
  return if $actual eq $enabled;
  die "unexpected bytes for $label\n" unless $actual eq $disabled;
  seek $file, $offset, 0 or die "cannot seek to $label: $!\n";
  print {$file} $enabled or die "cannot restore $label: $!\n";
}

restore_bytes(0x394ea, pack('H*', 'e98d01000000'), pack('H*', '0f848c010000'), 'photo sync view init');
restore_bytes(0x3a077, pack('H*', 'c3'), pack('H*', '55'), 'photo sync window open');
PERL
}

patch_aoa_control_timeouts() {
  local core="${BUILD_DIR}/HandShaker.app/Contents/Frameworks/SmartFinderCore.framework/Versions/A/SmartFinderCore"

  require_file "${core}"
  CORE_PATH="${core}" python3 - <<'PY' || fail "failed to set AOA control transfer timeouts"
import os
path = os.environ["CORE_PATH"]
# c7 44 24 08 imm32  is the timeout argument of libusb_control_transfer.
sites = (0x74B4E, 0x74F9B, 0x75081, 0x81AE7, 0x81E69, 0x8441B)
old = bytes.fromhex("c744240800000000")
new = bytes.fromhex("c7442408d0070000")  # 2000 ms
with open(path, "rb") as handle:
    data = bytearray(handle.read())
for offset in sites:
    current = bytes(data[offset:offset + 8])
    if current == new:
        continue
    if current != old:
        raise SystemExit(f"unexpected bytes at {offset:#x}: {current.hex()}")
    data[offset:offset + 8] = new
with open(path, "wb") as handle:
    handle.write(data)
PY
}

load_release_config

require_command codesign
require_command create-dmg
require_command lipo
require_command perl
require_command python3

if [ -f "${SMARTFINDER_CORE_PATCH_SCRIPT}" ]; then
  echo "🧩 正在应用 SmartFinderCore 运行时补丁..."
  sh "${SMARTFINDER_CORE_PATCH_SCRIPT}"
fi

# 1. 准备空壳
echo "🚀 开始组装 HandShaker.app..."
rm -rf "${BUILD_DIR}/HandShaker.app"
mkdir -p "${BUILD_DIR}/HandShaker.app"

# 2. 注入灵魂
cp -R "${APP_TEMPLATE_DIR}/Contents" "${BUILD_DIR}/HandShaker.app/"

echo "🔗 正在更新 Android 发布页地址..."
patch_accessory_download_url

# 2.1 避免系统 SearchFoundation.SFButton 与 HandShaker.SFButton 同名冲突
echo "🛠️ 正在修复旧版界面兼容性..."
patch_legacy_nib_button "${BUILD_DIR}/HandShaker.app/Contents/Resources/Preference.nib"
patch_legacy_nib_button "${BUILD_DIR}/HandShaker.app/Contents/Resources/SFPhotoSyncConfigView.nib"
restore_photo_sync_prompt

# 2.2 注入版本信息
echo "🏷️ 正在应用维护版版本号..."
apply_release_version

# 2.3 AOA 探测的 control transfer 超时为 0 时，主线程会永久卡住。
echo "⏱️ 正在给 AOA 探测设置超时..."
patch_aoa_control_timeouts

# 3. 重新签名
echo "🔐 正在进行本地重签名..."
codesign --force --deep --sign - "${BUILD_DIR}/HandShaker.app"

# 4. 像素级完全复刻打包模式
echo "📦 正在生成工业级 DMG 安装包..."

rm -f "${BUILD_DIR}/${RELEASE_DMG_NAME}"

DMG_STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/handshaker-dmg.XXXXXX")"
trap 'rm -rf "${DMG_STAGING_DIR}"' EXIT
cp -R "${BUILD_DIR}/HandShaker.app" "${DMG_STAGING_DIR}/"

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
  "${DMG_STAGING_DIR}/"

[ -f "${BUILD_DIR}/${RELEASE_DMG_NAME}" ] || fail "dmg packaging did not produce ${BUILD_DIR}/${RELEASE_DMG_NAME}"

echo "版本号: ${RELEASE_VERSION_NAME} (${RELEASE_BUILD_NUMBER})"
echo "架构: ${RELEASE_ARCH_NAME}"
echo "DMG: ${BUILD_DIR}/${RELEASE_DMG_NAME}"
echo "✅ 像素级完全复刻打包完成！"
