#!/bin/sh
# 组装 HandShaker macOS26 USB 联合诊断一shot 测试包.
#
# 用法:
#   tools/build_diagnostic_bundle.sh [输出目录] [Android诊断APK路径] [Mac DMG路径]
#
# 默认参数:
#   输出目录: ~/Downloads/HandShaker-macOS26-USB-OneShot-<版本后缀>
#   Android APK: 取自 handshaker-android-maintained 仓库 release.env 指向的签名 APK
#   Mac DMG: 本仓库 build/ 下最新构建
#
# 测试包结构 (与 2026-07 beta11 首发的 OneShot 包保持一致, 用户操作习惯不变):
#   .
#   ├── handshaker-mac-maintained-<版本>-x86_64.dmg   # Mac 端诊断版
#   ├── HandShaker-Android-USB-Diagnostic.apk         # Android 端诊断版 (脚本自动安装)
#   ├── HandShaker-USB-Diagnostics.command            # 联合诊断编排脚本
#   ├── platform-tools/                               # adb (供脚本查找设备/装APK/拉日志)
#   │   ├── adb
#   │   ├── NOTICE.txt
#   │   └── source.properties
#   ├── 使用说明.txt                                   # 用户操作指引
#   └── SHA256SUMS.txt                                # 包内文件校验和
#
# platform-tools 来源 (按顺序探测):
#   1. 上一个 OneShot 包内的 platform-tools (复用已验证版本)
#   2. ~/Library/Android/sdk/platform-tools
#   3. 提示手动下载: https://developer.android.com/tools/releases/platform-tools
#
# 交付: 输出目录 + 同名 .zip (ditto 打包, 保留 AppleDouble 元数据).

set -eu

script_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
repo_root=$(CDPATH= cd -- "${script_dir}/.." && pwd)
downloads_dir="${HOME}/Downloads"

android_repo="${HOME}/AIProjects/handshaker-android-maintained"
android_release_env="${android_repo}/build/release/handshaker-android-release.env"

fail() {
  printf '%s\n' "FAIL: $1" >&2
  exit 1
}

# ---- 参数 ----

bundle_dir_arg="${1:-}"
android_apk_arg="${2:-}"
mac_dmg_arg="${3:-}"

# ---- Mac DMG ----

if [ -n "${mac_dmg_arg}" ]; then
  mac_dmg="${mac_dmg_arg}"
else
  mac_dmg="$(ls -t "${repo_root}"/build/handshaker-mac-maintained-*.dmg 2>/dev/null | head -n 1 || true)"
fi
[ -n "${mac_dmg}" ] && [ -f "${mac_dmg}" ] || fail "未找到 Mac DMG. 先运行 ./build.sh 或通过参数3指定."
mac_dmg_name="$(basename "${mac_dmg}")"

# 从 DMG 文件名提取版本 (handshaker-mac-maintained-2.5.6-r3-beta13-usbdiag-x86_64.dmg -> r3-beta13-usbdiag)
bundle_suffix="$(printf '%s\n' "${mac_dmg_name}" | sed -E 's/^handshaker-mac-maintained-[0-9.]+-([^-]+.*u|x86_64)?-x86_64\.dmg$/\1/')"
case "${mac_dmg_name}" in
  handshaker-mac-maintained-*x86_64.dmg)
    bundle_suffix="$(printf '%s\n' "${mac_dmg_name}" | sed -E 's/^handshaker-mac-maintained-[0-9.]+-(.*)-x86_64\.dmg$/\1/')"
    ;;
  *)
    bundle_suffix="$(printf '%s\n' "${mac_dmg_name}" | sed -E 's/^handshaker-mac-maintained-(.*)\.dmg$/\1/')"
    ;;
esac

bundle_dir="${bundle_dir_arg:-${downloads_dir}/HandShaker-macOS26-USB-OneShot-${bundle_suffix}}"

# ---- Android 诊断 APK ----

if [ -n "${android_apk_arg}" ]; then
  android_apk="${android_apk_arg}"
elif [ -f "${android_release_env}" ]; then
  android_apk="$(sed -n 's/^HANDSHAKER_ANDROID_APK=//p' "${android_release_env}")"
else
  android_apk=""
fi
[ -n "${android_apk}" ] && [ -f "${android_apk}" ] || fail "未找到 Android 诊断 APK. 构建 handshaker-android-maintained 或通过参数2指定."

# ---- platform-tools ----

find_platform_tools() {
  local previous_bundle candidate

  for previous_bundle in "${downloads_dir}"/HandShaker-macOS26-USB-OneShot-*; do
    # 排除目标输出目录自身: rm -rf 后重建瞬间会被本函数误探测到半删状态.
    [ "${previous_bundle}" = "${bundle_dir}" ] && continue
    candidate="${previous_bundle}/platform-tools/adb"
    if [ -x "${candidate}" ]; then
      printf '%s\n' "${previous_bundle}/platform-tools"
      return 0
    fi
  done

  candidate="${HOME}/Library/Android/sdk/platform-tools/adb"
  if [ -x "${candidate}" ]; then
    printf '%s\n' "${HOME}/Library/Android/sdk/platform-tools"
    return 0
  fi

  return 1
}

platform_tools_src=""
if ! platform_tools_src="$(find_platform_tools)"; then
  fail "未找到 platform-tools. 参考: https://developer.android.com/tools/releases/platform-tools"
fi

# ---- 组装 ----

printf '%s\n' "==> Mac DMG: ${mac_dmg}"
printf '%s\n' "==> Android APK: ${android_apk}"
printf '%s\n' "==> platform-tools: ${platform_tools_src}"
printf '%s\n' "==> 输出目录: ${bundle_dir}"

rm -rf "${bundle_dir}"
mkdir -p "${bundle_dir}"

cp "${mac_dmg}" "${bundle_dir}/${mac_dmg_name}"
cp "${android_apk}" "${bundle_dir}/HandShaker-Android-USB-Diagnostic.apk"
cp "${script_dir}/HandShaker-Diagnostics.command" "${bundle_dir}/HandShaker-USB-Diagnostics.command"
cp "${script_dir}/usb_link.awk" "${bundle_dir}/usb_link.awk"
cp "${script_dir}/USB联合诊断使用说明.txt" "${bundle_dir}/使用说明.txt"
chmod 755 "${bundle_dir}/HandShaker-USB-Diagnostics.command"

mkdir -p "${bundle_dir}/platform-tools"
cp "${platform_tools_src}/adb" "${bundle_dir}/platform-tools/adb"
if [ -f "${platform_tools_src}/NOTICE.txt" ]; then
  cp "${platform_tools_src}/NOTICE.txt" "${bundle_dir}/platform-tools/NOTICE.txt"
fi
if [ -f "${platform_tools_src}/source.properties" ]; then
  cp "${platform_tools_src}/source.properties" "${bundle_dir}/platform-tools/source.properties"
fi
chmod 755 "${bundle_dir}/platform-tools/adb"

# ---- 校验和 ----

(
  cd "${bundle_dir}"
  shasum -a 256 \
    "${mac_dmg_name}" \
    "HandShaker-Android-USB-Diagnostic.apk" \
    "HandShaker-USB-Diagnostics.command" \
    "使用说明.txt" \
    "platform-tools/adb" \
    "platform-tools/NOTICE.txt" \
    "platform-tools/source.properties" \
    >SHA256SUMS.txt
)

# ---- 打 zip ----

bundle_zip="${bundle_dir}.zip"
rm -f "${bundle_zip}"
(
  cd "${downloads_dir}"
  ditto -c -k --keepParent "${bundle_dir}" "$(basename "${bundle_zip}")"
)

printf '%s\n' ""
printf '%s\n' "✅ 测试包已生成:"
printf '%s\n' "    目录: ${bundle_dir}"
printf '%s\n' "    压缩: ${bundle_zip}"
printf '%s\n' ""
printf '%s\n' "下一步: 将 ${bundle_zip} 发给测试用户, 用户按包内 使用说明.txt 操作."
