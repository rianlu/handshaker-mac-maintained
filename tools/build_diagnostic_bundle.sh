#!/bin/bash
# Assemble one matched Mac/Android diagnostic bundle. Refuse existing outputs.
# Usage: tools/build_diagnostic_bundle.sh [output-directory] [Android-APK] [Mac-DMG]
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)
android_repo="${HANDSHAKER_ANDROID_REPO:-$HOME/AIProjects/handshaker-android-maintained}"
android_build="${HANDSHAKER_ANDROID_BUILD_DIR:-$android_repo/build/release}"
mac_build="${HANDSHAKER_MAC_BUILD_DIR:-$repo_root/build}"
case "$mac_build" in /*) ;; *) mac_build="$repo_root/$mac_build" ;; esac
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
get_value() { awk -v key="$1" 'index($0,key "=")==1 {print substr($0,length(key)+2); exit}' "$2"; }

# Resolve the configured release, never an unrelated DMG selected by modification time.
# shellcheck disable=SC1091
. "$repo_root/release.conf"
[[ "${DIAGNOSTIC_BUNDLE_ID:-}" =~ ^[0-9]{8}-[0-9]{2}$ ]] || fail "请在 release.conf 设置测试包编号, 格式为 YYYYMMDD-NN."
mac_version="$RELEASE_BASE_VERSION${RELEASE_SUFFIX:+-$RELEASE_SUFFIX}"
mac_arch=$(lipo -archs "$repo_root/App_Template/Contents/MacOS/HandShaker")
[ "$mac_arch" = x86_64 ] || fail "此诊断模块只支持已校验的 x86_64 Core."
mac_dmg="${3:-$mac_build/handshaker-mac-maintained-$mac_version-$mac_arch.dmg}"
[ -f "$mac_dmg" ] || fail "未找到当前版本 DMG. 请先构建或通过第三个参数指定."
android_apk="${2:-}"
if [ -z "$android_apk" ] && [ -f "$android_build/handshaker-android-release.env" ]; then
  android_apk=$(get_value HANDSHAKER_ANDROID_APK "$android_build/handshaker-android-release.env")
fi
[ -n "$android_apk" ] && [ -f "$android_apk" ] || fail "未找到 Android APK. 请先构建或通过第二个参数指定."

bundle_dir="${1:-$HOME/Downloads/HandShaker-USB-Test-$DIAGNOSTIC_BUNDLE_ID}"
bundle_dir="${bundle_dir%/}"
[ -n "$bundle_dir" ] || fail "输出目录不能为空."
case "$bundle_dir" in /*) ;; *) bundle_dir="$PWD/$bundle_dir" ;; esac
bundle_zip="$bundle_dir.zip"
[ ! -e "$bundle_dir" ] && [ ! -e "$bundle_zip" ] || fail "输出目录或同名 ZIP 已存在. 请指定新目录, 现有文件不会被覆盖."

sdk="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
platform_tools="${HANDSHAKER_PLATFORM_TOOLS:-$sdk/platform-tools}"
[ -x "$platform_tools/adb" ] || fail "未找到 platform-tools/adb."
aapt="${HANDSHAKER_AAPT:-$sdk/build-tools/36.0.0/aapt2}"
apksigner="${HANDSHAKER_APKSIGNER:-$sdk/build-tools/36.0.0/apksigner}"
[ -x "$aapt" ] && [ -x "$apksigner" ] || fail "需要 Android build-tools 36.0.0, 或设置 HANDSHAKER_AAPT/HANDSHAKER_APKSIGNER."
signing_info=$("$apksigner" verify --print-certs "$android_apk") || fail "Android APK 签名校验失败."
android_signer_sha256=$(printf '%s\n' "$signing_info" | sed -n 's/^Signer #1 certificate SHA-256 digest: //p')
[ -n "$android_signer_sha256" ] || fail "未取得 Android APK 的签名证书摘要."
diagnostic_script_revision=$(sed -n 's/^script_revision="\(.*\)"$/\1/p' "$script_dir/HandShaker-Diagnostics.command")
[ -n "$diagnostic_script_revision" ] || fail "未取得诊断脚本修订号."
badging=$("$aapt" dump badging "$android_apk")
android_name=$(printf '%s\n' "$badging" | sed -n "s/^package:.* versionName='\([^']*\)'.*/\1/p")
android_code=$(printf '%s\n' "$badging" | sed -n "s/^package:.* versionCode='\([^']*\)'.*/\1/p")
grep -q "^package: name='com.smartisanos.smartfolder.aoa' " <<<"$badging" || fail "Android APK 包名不匹配."
expected_code=$(get_value RELEASE_VERSION_CODE "$android_repo/tools/release.conf")
[ -n "$android_code" ] && [ "$android_code" = "$expected_code" ] || fail "Android APK 不是当前配置的诊断版本."

# Inspect the actual DMG payload and its signature before writing the bundle.
mount_root=$(mktemp -d "${TMPDIR:-/tmp}/handshaker-bundle-check.XXXXXX")
mount_dir="$mount_root/mount"
mkdir "$mount_dir"
mounted=0
cleanup() {
  if [ "$mounted" = 1 ]; then hdiutil detach "$mount_dir" >/dev/null 2>&1 || true; fi
  rmdir "$mount_dir" "$mount_root" 2>/dev/null || true
}
trap cleanup EXIT
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$mount_dir" "$mac_dmg" >/dev/null
mounted=1
app="$mount_dir/HandShaker.app"
actual_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")
actual_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
[ "$actual_build" = "$RELEASE_BUILD_NUMBER" ] && [ "$actual_version" = "$mac_version" ] || fail "DMG 内实际应用版本与当前配置不一致."
codesign --verify --deep --strict "$app" || fail "DMG 内应用签名校验失败."
hdiutil detach "$mount_dir" >/dev/null
mounted=0

mkdir -p "$(dirname "$bundle_dir")"
mkdir "$bundle_dir"
mac_name="1-安装Mac端.dmg"
cp -X "$mac_dmg" "$bundle_dir/$mac_name"
cp -X "$android_apk" "$bundle_dir/HandShaker-Android-USB-Diagnostic.apk"
cp -X "$script_dir/HandShaker-Diagnostics.command" "$bundle_dir/2-开始测试.command"
cp -X "$script_dir/usb_link.awk" "$bundle_dir/usb_link.awk"
cp -X "$script_dir/USB联合诊断使用说明.txt" "$bundle_dir/使用说明.txt"
mkdir "$bundle_dir/platform-tools"
cp -X "$platform_tools/adb" "$bundle_dir/platform-tools/adb"
for attachment in NOTICE NOTICE.txt source.properties; do
  [ ! -f "$platform_tools/$attachment" ] || cp -X "$platform_tools/$attachment" "$bundle_dir/platform-tools/$attachment"
done
if [ -d "$platform_tools/lib64" ]; then cp -RX "$platform_tools/lib64" "$bundle_dir/platform-tools/"; fi
chmod 755 "$bundle_dir/2-开始测试.command" "$bundle_dir/platform-tools/adb"
{
  printf 'SCHEMA=4\nBUNDLE_ID=%s\nSCRIPT_REVISION=%s\nMAC_VERSION=%s\nMAC_BUILD=%s\nMAC_DMG=%s\n' "$DIAGNOSTIC_BUNDLE_ID" "$diagnostic_script_revision" "$actual_version" "$actual_build" "$mac_name"
  printf 'ANDROID_VERSION_NAME=%s\nANDROID_VERSION_CODE=%s\nOBSERVE_MODE=user-controlled\nTEST_FILE_BYTES=268435456\n' "$android_name" "$android_code"
  printf 'ANDROID_SIGNER_CERT_SHA256=%s\n' "$android_signer_sha256"
  printf 'CREATED_UTC=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
} >"$bundle_dir/diagnostic-manifest.txt"
(
  cd "$bundle_dir"
  # The checksum file is explicitly excluded from the input list.
  # shellcheck disable=SC2094
  while IFS= read -r -d '' item; do shasum -a 256 "$item"; done \
    < <(find . -type f ! -name SHA256SUMS.txt -print0) >SHA256SUMS.txt
  shasum -a 256 -c SHA256SUMS.txt
)
COPYFILE_DISABLE=1 ditto -c -k --keepParent --norsrc --noextattr --noqtn "$bundle_dir" "$bundle_zip"
unzip -tq "$bundle_zip"
printf '\n联合诊断包已生成:\n%s\n' "$bundle_zip"
