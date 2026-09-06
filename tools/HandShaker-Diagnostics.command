#!/bin/zsh

set -u

timestamp="$(date '+%Y%m%d-%H%M%S')"
# POSIX 兼容的脚本目录解析: 双击(zsh绝对路径)、cd后 sh/bash/zsh 手动执行(相对/绝对路径) 均正确.
# 不用 zsh 专有 ${0:A:h}: 在 sh/bash 下它展开为空导致 script_dir 为空, 包内文件全部找不到.
script_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
out_dir="${HOME}/Desktop/HandShaker-Diagnostics-${timestamp}"
common_dir="${out_dir}/common"
app_name="HandShaker"
app_path="/Applications/HandShaker.app"
app_executable="${app_path}/Contents/MacOS/HandShaker"
android_package="com.smartisanos.smartfolder.aoa"
android_external_dir="/sdcard/Android/data/${android_package}/files"
diagnostic_apk="${script_dir}/HandShaker-Android-USB-Diagnostic.apk"
adb_path=""
adb_serial=""
sampler_pid=""
usb_monitor_pid=""
bonjour_monitor_pid=""
log_monitor_pid=""

say_step() {
  printf '\n%s\n' "$1"
}

press_enter() {
  printf '\n%s' "$1"
  read -r _
}

run_capture() {
  local output="$1"
  shift
  {
    printf '$'
    printf ' %q' "$@"
    printf '\n\n'
    "$@"
  } >"${output}" 2>&1
}

ask_text() {
  local output="$1"
  shift

  printf '\n%s\n' "$1"
  printf '%s\n' "如果不方便输入, 可以直接按回车跳过, 但请另外拍照发给维护者."
  printf '%s' "> "
  read -r answer
  printf '%s\n' "${answer}" >"${output}"
}

ask_choice() {
  local output="$1"
  shift

  printf '\n%s\n' "$1"
  shift
  for line in "$@"; do
    printf '%s\n' "$line"
  done
  printf '%s' "输入选项后按回车: "
  read -r answer
  printf '%s\n' "${answer}" >"${output}"
}

find_adb() {
  local candidate

  for candidate in \
    "${script_dir}/platform-tools/adb" \
    "${script_dir}/adb" \
    "${HOME}/Library/Android/sdk/platform-tools/adb"; do
    if [ -x "${candidate}" ]; then
      adb_path="${candidate}"
      return 0
    fi
  done

  candidate="$(command -v adb 2>/dev/null || true)"
  if [ -n "${candidate}" ] && [ -x "${candidate}" ]; then
    adb_path="${candidate}"
    return 0
  fi

  return 1
}

adb_online() {
  [ -n "${adb_path}" ] && [ -n "${adb_serial}" ] && \
    [ "$("${adb_path}" -s "${adb_serial}" get-state 2>/dev/null || true)" = "device" ]
}

adb_capture() {
  local output="$1"
  shift
  run_capture "${output}" "${adb_path}" -s "${adb_serial}" "$@"
}

select_adb_device() {
  local output_dir="$1"
  local listing usb_serials serial_count

  listing="$("${adb_path}" devices -l 2>&1)"
  printf '%s\n' "${listing}" >"${output_dir}/adb-devices.txt"
  usb_serials="$(printf '%s\n' "${listing}" | awk 'NR > 1 && $2 == "device" && $0 ~ / usb:/ {print $1}')"
  serial_count="$(printf '%s\n' "${usb_serials}" | awk 'NF {count++} END {print count + 0}')"
  if [ "${serial_count}" = "1" ]; then
    adb_serial="${usb_serials}"
    return 0
  fi

  return 1
}

capture_android_state() {
  local output_dir="$1"
  local label="$2"

  mkdir -p "${output_dir}/android"
  adb_capture "${output_dir}/android/time-${label}.txt" shell date '+%Y-%m-%dT%H:%M:%S%z'
  adb_capture "${output_dir}/android/uptime-${label}.txt" shell cat /proc/uptime
  adb_capture "${output_dir}/android/getprop-${label}.txt" shell getprop
  adb_capture "${output_dir}/android/dumpsys-usb-${label}.txt" shell dumpsys usb
  adb_capture "${output_dir}/android/usb-functions-${label}.txt" shell cmd usb get-functions
  adb_capture "${output_dir}/android/adb-enabled-${label}.txt" shell settings get global adb_enabled
  adb_capture "${output_dir}/android/package-${label}.txt" shell dumpsys package "${android_package}"
  adb_capture "${output_dir}/android/services-${label}.txt" shell dumpsys activity services "${android_package}"
  adb_capture "${output_dir}/android/activity-top-${label}.txt" shell dumpsys activity top
  adb_capture "${output_dir}/android/processes-${label}.txt" shell ps -A
}

prepare_android_usb_diagnostics() {
  local scenario_dir="$1"
  local attempt install_status init_log remaining_log

  mkdir -p "${scenario_dir}/android"
  if ! find_adb; then
    printf '%s\n' "未找到 ADB. 测试包必须包含 platform-tools/adb." | tee "${scenario_dir}/android/preflight-error.txt"
    return 1
  fi
  if [ ! -f "${diagnostic_apk}" ]; then
    printf '%s\n' "未找到诊断 APK: ${diagnostic_apk}" | tee "${scenario_dir}/android/preflight-error.txt"
    return 1
  fi

  run_capture "${scenario_dir}/android/adb-version.txt" "${adb_path}" version
  run_capture "${scenario_dir}/android/adb-start-server.txt" "${adb_path}" start-server

  for attempt in 1 2 3; do
    if select_adb_device "${scenario_dir}/android"; then
      break
    fi
    if [ "${attempt}" = "3" ]; then
      printf '%s\n' "ADB 预检失败: 未找到唯一的已授权物理 USB 设备." | tee "${scenario_dir}/android/preflight-error.txt"
      return 1
    fi
    printf '%s\n' "请保持手机连接, 开启 USB 调试并允许这台 Mac; 如果连接了多个调试设备, 请断开其他设备."
    press_enter "完成后按回车重新检测..."
  done

  printf '%s\n' "${adb_serial}" >"${scenario_dir}/android/adb-serial.txt"

  # Play Protect 首次安装拦截 (INSTALL_FAILED_VERIFICATION_FAILURE) 重试即过.
  for attempt in 1 2 3; do
    {
      printf '$ %q -s %q install -r %q\n\n' "${adb_path}" "${adb_serial}" "${diagnostic_apk}"
      "${adb_path}" -s "${adb_serial}" install -r "${diagnostic_apk}"
    } >"${scenario_dir}/android/apk-install.txt" 2>&1
    install_status=$?
    if [ "${install_status}" -eq 0 ] && grep -q 'Success' "${scenario_dir}/android/apk-install.txt"; then
      break
    fi
    if [ "${attempt}" = "3" ]; then
      printf '%s\n' "诊断 APK 安装失败 (可能被手机 Play Protect 拦截, 可在手机上关闭应用扫描后重跑)." | tee "${scenario_dir}/android/preflight-error.txt"
      return 1
    fi
    sleep 2
  done

  # 部分机型存在应用分身/多用户副本 (User 900 等), 会使 am start 弹出"选择打开方式"
  # 导致脚本卡死. 先移除非当前用户的副本, 只保留机主 (User 0) 实例.
  current_user=$("${adb_path}" -s "${adb_serial}" shell am get-current-user 2>/dev/null | tr -d '[:space:]')
  : "${current_user:=0}"
  if [ "${current_user}" != "900" ] && "${adb_path}" -s "${adb_serial}" shell pm list packages --user 900 2>/dev/null | grep -q "${android_package}"; then
    adb_capture "${scenario_dir}/android/dual-app-uninstall.txt" shell pm uninstall --user 900 "${android_package}"
  fi
  adb_capture "${scenario_dir}/android/package-enable.txt" shell pm enable "${android_package}"

  adb_capture "${scenario_dir}/android/app-force-stop.txt" shell am force-stop "${android_package}"
  adb_capture "${scenario_dir}/android/old-diagnostic-log-remove.txt" shell rm -f \
    "${android_external_dir}/handshaker-usb-diagnostic.log" \
    "${android_external_dir}/handshaker-usb-diagnostic.log.previous"
  remaining_log="$("${adb_path}" -s "${adb_serial}" shell ls "${android_external_dir}/handshaker-usb-diagnostic.log" 2>/dev/null || true)"
  if [ -n "${remaining_log}" ]; then
    printf '%s\n' "无法清空 Android 旧诊断日志, 本次 USB 测试不会开始." | tee "${scenario_dir}/android/preflight-error.txt"
    return 1
  fi
  adb_capture "${scenario_dir}/android/logcat-clear.txt" logcat -c
  # 显式组件启动; 若机型解析到多实例弹"选择打开方式" (ResolverActivity) 则
  # 退化为 monkey 包名启动, 保证非交互环境下应用一定能被拉起.
  adb_capture "${scenario_dir}/android/app-launch.txt" shell am start -W -n "${android_package}/.MainActivity"
  if grep -q 'ResolverActivity' "${scenario_dir}/android/app-launch.txt" 2>/dev/null; then
    adb_capture "${scenario_dir}/android/app-launch-monkey.txt" shell monkey -p "${android_package}" -c android.intent.category.LAUNCHER 1
  fi
  sleep 3

  init_log="$("${adb_path}" -s "${adb_serial}" shell cat "${android_external_dir}/handshaker-usb-diagnostic.log" 2>/dev/null || true)"
  printf '%s\n' "${init_log}" >"${scenario_dir}/android/diagnostic-init-check.txt"
  if ! printf '%s\n' "${init_log}" | grep -q 'APP_START'; then
    printf '%s\n' "Android 持久诊断日志未生成, 本次 USB 测试不会开始." | tee "${scenario_dir}/android/preflight-error.txt"
    return 1
  fi

  capture_android_state "${scenario_dir}" "before"
  return 0
}

collect_android_usb_evidence() {
  local scenario_dir="$1"
  local android_dir="${scenario_dir}/android"

  if ! adb_online; then
    close_handshaker || true
    printf '%s\n' "USB 连接过程中 ADB 已断开——问题刚好被记录到了. 不需要重新测试."
    printf '%s\n' "现在只需拔下数据线再插入一次, 等手机重新出现 USB 调试授权或文件传输状态."
    press_enter "重新插好并允许 USB 调试后按回车, 脚本会等待设备恢复..."
    for _ in {1..60}; do
      adb_online && break
      sleep 1
    done
  fi

  if ! adb_online; then
    printf '%s\n' "ADB 未恢复, Android 证据无法拉取." | tee "${android_dir}/postflight-error.txt"
    return 1
  fi

  capture_android_state "${scenario_dir}" "after"
  adb_capture "${android_dir}/logcat-full.txt" logcat -d -b all -v threadtime
  LC_ALL=C grep -Ei 'HandShakerUSB|HandShakerDiag|USB_ACCESSORY|Usb(Device|Host|Port|Service|Manager)|Accessory|AndroidRuntime|FATAL EXCEPTION' \
    "${android_dir}/logcat-full.txt" >"${android_dir}/logcat-usb-focused.txt" 2>/dev/null || true
  adb_capture "${android_dir}/persistent-log-list.txt" shell ls -la "${android_external_dir}"
  "${adb_path}" -s "${adb_serial}" pull \
    "${android_external_dir}/handshaker-usb-diagnostic.log" \
    "${android_dir}/handshaker-usb-diagnostic.log" >"${android_dir}/persistent-log-pull.txt" 2>&1 || true
  "${adb_path}" -s "${adb_serial}" pull \
    "${android_external_dir}/handshaker-usb-diagnostic.log.previous" \
    "${android_dir}/handshaker-usb-diagnostic.log.previous" >>"${android_dir}/persistent-log-pull.txt" 2>&1 || true
  adb_capture "${android_dir}/persistent-log-internal.txt" exec-out run-as "${android_package}" \
    cat files/handshaker-usb-diagnostic.log
  return 0
}

find_app() {
  [ -d "${app_path}" ]
}

close_handshaker() {
  if pgrep -x "${app_name}" >/dev/null 2>&1; then
    osascript -e 'tell application "HandShaker" to quit' >/dev/null 2>&1 || true
    for _ in {1..50}; do
      pgrep -x "${app_name}" >/dev/null 2>&1 || break
      sleep 0.1
    done
  fi

  if pgrep -x "${app_name}" >/dev/null 2>&1; then
    printf '%s\n' "无法正常关闭正在运行的 HandShaker." | tee "${common_dir}/app-still-running.txt"
    return 1
  fi

  return 0
}

open_handshaker() {
  if ! find_app; then
    printf '%s\n' "未找到 /Applications/HandShaker.app. 请先打开 DMG, 将 HandShaker 拖入应用程序文件夹." | tee "${common_dir}/app-not-found.txt"
    return 1
  fi

  close_handshaker || return 1

  open "${app_path}"
}

find_pid() {
  ps -axo pid=,command= | awk -v executable="${app_executable}" '$2 == executable { print $1; exit }'
}

wait_for_handshaker() {
  local pid

  for _ in {1..20}; do
    pid="$(find_pid || true)"
    if [ -n "${pid}" ]; then
      printf 'HandShaker PID: %s\n' "${pid}" | tee -a "${common_dir}/pid.txt"
      run_capture "${common_dir}/app-process-${pid}.txt" ps -p "${pid}" -o pid,ppid,stat,%cpu,%mem,etime,command
      return 0
    fi
    sleep 1
  done

  return 1
}

capture_app_state() {
  local output_dir="$1"
  local label="$2"
  local pid

  pid="$(find_pid || true)"
  if [ -z "${pid}" ]; then
    printf '%s\n' "HandShaker process not found" >"${output_dir}/app-state-${label}.txt"
    return 0
  fi

  run_capture "${output_dir}/app-state-${label}.txt" ps -p "${pid}" -o pid,ppid,stat,%cpu,%mem,etime,command
  run_capture "${output_dir}/app-top-${label}.txt" top -l 1 -pid "${pid}" -stats pid,command,cpu,mem,threads,state,time
  run_capture "${output_dir}/vmmap-summary-${label}.txt" vmmap -summary "${pid}"
  run_capture "${output_dir}/lsof-${label}.txt" lsof -p "${pid}"
  run_capture "${output_dir}/footprint-${label}.txt" footprint "${pid}"
}

capture_sample() {
  local scenario_dir="$1"
  local label="$2"
  local pid

  mkdir -p "${scenario_dir}/samples"
  pid="$(find_pid || true)"

  if [ -z "${pid}" ]; then
    printf '%s\n' "HandShaker process not found" >"${scenario_dir}/samples/sample-${label}.txt"
    return 0
  fi

  run_capture "${scenario_dir}/ps-${label}.txt" ps -p "${pid}" -o pid,ppid,stat,%cpu,%mem,etime,command
  /usr/bin/sample "${pid}" 5 -file "${scenario_dir}/samples/sample-${label}.txt" >"${scenario_dir}/samples/sample-${label}.stderr.txt" 2>&1
}

start_sampler() {
  local scenario_dir="$1"
  local stop_file="$2"
  local index=1

  (
    while [ ! -f "${stop_file}" ]; do
      capture_sample "${scenario_dir}" "$(printf '%03d' "${index}")"
      index=$((index + 1))
      sleep 1
    done
  ) &
  sampler_pid="$!"
}

stop_sampler() {
  local sampler_pid="$1"
  local stop_file="$2"

  touch "${stop_file}"
  wait "${sampler_pid}" 2>/dev/null || true
}

start_usb_monitor() {
  local scenario_dir="$1"
  local stop_file="$2"

  (
    : >"${scenario_dir}/usb-enumeration-timeline.txt"
    while [ ! -f "${stop_file}" ]; do
      {
        printf '\n=== %s epoch=%s ===\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$(date '+%s')"
        ioreg -p IOUSB -l -w0 | awk '/"USB Product Name"|"USB Vendor Name"|"USB Serial Number"|"idVendor"|"idProduct"|"locationID"|"Device Speed"|UsbLinkSpeed|USBPortType|controller-statistics|kControllerStat|ErrorCount|ErrCnt|USBDeviceErrors|kUSB.*Error/'
      } >>"${scenario_dir}/usb-enumeration-timeline.txt" 2>&1
      sleep 1
    done
  ) &
  usb_monitor_pid="$!"
}

stop_usb_monitor() {
  local monitor_pid="$1"
  local stop_file="$2"

  touch "${stop_file}"
  wait "${monitor_pid}" 2>/dev/null || true
}

capture_usb_snapshot() {
  local scenario_dir="$1"
  local label="$2"

  run_capture "${scenario_dir}/usb-${label}.txt" system_profiler SPUSBDataType
  run_capture "${scenario_dir}/ioreg-usb-${label}.txt" ioreg -p IOUSB -l -w0
  run_capture "${scenario_dir}/ioreg-usbhost-${label}.txt" ioreg -r -c IOUSBHostDevice -l -w0
  run_capture "${scenario_dir}/ioreg-iousbhost-interface-${label}.txt" ioreg -r -c IOUSBHostInterface -l -w0
  run_capture "${scenario_dir}/ioreg-smartisan-xiaomi-google-${label}.txt" sh -c "ioreg -p IOUSB -l -w0; ioreg -r -c IOUSBHostDevice -l -w0"
}

start_log_monitor() {
  local scenario_dir="$1"
  local name="$2"
  local predicate

  if [ "${name}" = "usb" ]; then
    predicate='process == "HandShaker" OR eventMessage CONTAINS[c] "HandShaker" OR eventMessage CONTAINS[c] "HandShakerMaintained" OR eventMessage CONTAINS[c] "SmartFinder" OR eventMessage CONTAINS[c] "USBHost" OR eventMessage CONTAINS[c] "libusb" OR eventMessage CONTAINS[c] "Accessory" OR eventMessage CONTAINS[c] "AOA" OR eventMessage CONTAINS[c] "Android" OR eventMessage CONTAINS[c] "Xiaomi" OR eventMessage CONTAINS[c] "Smartisan"'
  else
    predicate='process == "HandShaker" OR eventMessage CONTAINS[c] "HandShaker" OR eventMessage CONTAINS[c] "HandShakerMaintained" OR eventMessage CONTAINS[c] "SmartFinder" OR eventMessage CONTAINS[c] "Local Network" OR eventMessage CONTAINS[c] "Bonjour" OR eventMessage CONTAINS[c] "_handshaker_ssp" OR eventMessage CONTAINS[c] "nw_connection"'
  fi

  /usr/bin/log stream --style syslog --level debug --predicate "${predicate}" >"${scenario_dir}/log-stream-${name}.txt" 2>&1 &
  log_monitor_pid="$!"
}

stop_log_monitor() {
  local monitor_pid="$1"

  if [ -n "${monitor_pid}" ]; then
    kill "${monitor_pid}" 2>/dev/null || true
    wait "${monitor_pid}" 2>/dev/null || true
  fi
}

collect_handshaker_files() {
  local output_dir="$1"

  mkdir -p "${output_dir}/files"
  run_capture "${output_dir}/files/app-support-size.txt" sh -c 'du -sh "$HOME/Library/Application Support/HandShaker" "$HOME/Library/Caches/HandShaker" "$HOME/Library/Logs/HandShaker" 2>/dev/null || true'
  run_capture "${output_dir}/files/recent-diagnostic-reports.txt" sh -c 'find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -iname "HandShaker*" -mtime -7 -print -exec ls -lh {} \; 2>/dev/null || true'
  run_capture "${output_dir}/files/recent-handshaker-files.txt" sh -c 'find "$HOME/Library/Application Support/HandShaker" "$HOME/Library/Caches" "$HOME/Library/Logs" -maxdepth 4 \( -iname "*HandShaker*" -o -iname "*SmartFinder*" \) -mtime -7 -print 2>/dev/null | head -300'
  if [ -d "${HOME}/Library/Application Support/HandShaker/logs" ]; then
    ditto "${HOME}/Library/Application Support/HandShaker/logs" "${output_dir}/files/handshaker-logs"
  fi
}

start_bonjour_monitor() {
  local scenario_dir="$1"
  local stop_file="$2"

  (
    while [ ! -f "${stop_file}" ]; do
      date
      script -q /dev/null dns-sd -B _handshaker_ssp._tcp local &
      local dns_pid="$!"
      sleep 10
      kill "${dns_pid}" 2>/dev/null || true
      wait "${dns_pid}" 2>/dev/null || true
      sleep 2
    done
  ) >"${scenario_dir}/bonjour-browse.txt" 2>&1 &
  bonjour_monitor_pid="$!"
}

stop_bonjour_monitor() {
  local monitor_pid="$1"
  local stop_file="$2"

  touch "${stop_file}"
  wait "${monitor_pid}" 2>/dev/null || true
}

collect_common() {
  say_step "正在收集基础信息..."
  run_capture "${common_dir}/system.txt" sw_vers
  run_capture "${common_dir}/hardware.txt" system_profiler SPHardwareDataType
  run_capture "${common_dir}/disk.txt" df -h
  run_capture "${common_dir}/memory-pressure.txt" memory_pressure
  run_capture "${common_dir}/processes-handshaker-before.txt" pgrep -afil "HandShaker|SmartFinder"
  collect_handshaker_files "${common_dir}"

  if find_app; then
    run_capture "${common_dir}/security-assessment.txt" spctl --assess --type execute --verbose=4 "${app_path}"
    run_capture "${common_dir}/app-codesign.txt" codesign -dv --verbose=4 "${app_path}"
    run_capture "${common_dir}/app-info-plist.txt" plutil -p "${app_path}/Contents/Info.plist"
    run_capture "${common_dir}/app-fingerprints.txt" sh -c "shasum -a 256 '${app_path}/Contents/MacOS/HandShaker' '${app_path}/Contents/Frameworks/SmartFinderCore.framework/Versions/A/CorePatch' '${app_path}/Contents/Frameworks/SmartFinderCore.framework/Versions/A/SmartFinderCore' 2>/dev/null"
  else
    printf '%s\n' "HandShaker.app not found in /Applications." >"${common_dir}/app-not-found.txt"
  fi
}

evidence_has() {
  local pattern="$1"
  shift
  local file

  for file in "$@"; do
    if [ -f "${file}" ] && LC_ALL=C grep -Eq "${pattern}" "${file}" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

evidence_tree_has() {
  local pattern="$1"
  local directory="$2"

  [ -d "${directory}" ] && LC_ALL=C grep -ERq "${pattern}" "${directory}" 2>/dev/null
}


# USB 链路预检面板: 插线状态下向用户展示当前链路拓扑与速率, 并标记可疑配置.
# 速率优先取 UsbLinkSpeed(新机型), 无则用 USBSpeed 枚举(全机型兼容):
# 0=未知 1=低速1.5M 2=全速12M 3=高速480M 4=超速5G 5=超速+10G及以上.
print_usb_link_report() {
  local scenario_dir="$1"
  local report="${scenario_dir}/usb-link-report.txt"
  local raw raw2 phone_name phone_speed_label hub_names vendor_line
  raw="$(ioreg -p IOUSB -l -w0 2>/dev/null)"
  raw2="$(ioreg -r -c IOUSBHostDevice -l -w0 2>/dev/null)"
  printf '%s\n' "${raw}" >"${scenario_dir}/usb-tree-raw.txt"

  # 手机识别: 已知厂商产品名, 或 AOA VID 0x18d1/6353 出现即视为安卓配件
  phone_name="$(printf '%s\n' "${raw}" | grep -E '"USB Product Name" = "(一加|OnePlus|Xiaomi|Redmi|Samsung|Google|moto|Pixel)' | head -1 | sed -E 's/.*"USB Product Name" = "([^"]*)".*/\1/')"
  if [ -z "${phone_name}" ]; then
    vendor_line="$(printf '%s\n' "${raw}" | grep -m1 '"idVendor" = 6353')"
    [ -z "${vendor_line}" ] && vendor_line="$(printf '%s\n' "${raw2}" | grep -m1 '"idVendor" = 6353')"
    if [ -n "${vendor_line}" ]; then
      phone_name="$(printf '%s\n' "${raw}" | grep -m1 '"USB Product Name"' | sed -E 's/.*"USB Product Name" = "([^"]*)".*/\1/') (AOA 模式)"
    fi
  fi

  # 链路速率: UsbLinkSpeed(优先, 数值型) 或 USBSpeed(枚举型)
  local speed_raw speed_num
  speed_raw="$(printf '%s\n' "${raw}" | grep -m1 '"UsbLinkSpeed" = ')"
  if [ -z "${speed_raw}" ]; then
    speed_raw="$(printf '%s\n' "${raw2}" | grep -m1 '"USBSpeed" = ')"
  fi
  speed_num="$(printf '%s\n' "${speed_raw}" | grep -oE '[0-9]+' | head -1)"
  case "${speed_num}" in
    5) phone_speed_label="SuperSpeedPlus (10Gbps 或以上) - 老程序可能无法识别!" ;;
    4) phone_speed_label="SuperSpeed (5Gbps)" ;;
    3) phone_speed_label="High-Speed (480Mbps, USB 2.0)" ;;
    2) phone_speed_label="Full-Speed (12Mbps)" ;;
    1) phone_speed_label="Low-Speed (1.5Mbps)" ;;
    *) phone_speed_label="未知 (${speed_raw:-未取到})" ;;
  esac

  hub_names="$(printf '%s\n' "${raw}" | grep -E '"USB Product Name" = ".*(Hub|HUB).*"' | sed -E 's/.*"USB Product Name" = "([^"]*)".*/\1/' | paste -sd ' / ' -)"

  {
    printf 'USB 链路预检报告\n'
    printf '时间: %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'macOS: %s (Build %s)\n' "$(sw_vers -productVersion 2>/dev/null || echo '?')" "$(sw_vers -buildVersion 2>/dev/null || echo '?')"
    printf '机型: %s / %s\n\n' "$(sysctl -n hw.model 2>/dev/null || echo '?')" "$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo '?')"
    printf '检测到手机: %s\n' "${phone_name:-未识别 (未连接或非已知厂商)}"
    printf '链路速率: %s\n' "${phone_speed_label}"
    if [ -n "${hub_names}" ]; then
      printf '经过的集线器/坞: %s\n' "${hub_names}"
    else
      printf '经过的集线器/坞: 无 (直连)\n'
    fi
  } | tee "${report}"

  printf '%s\n' ""
  if [ -n "${hub_names}" ]; then
    printf '%s\n' "⚠️  注意: 你经过了扩展坞/集线器连接. 部分坞会定时断开静默设备, 若测试中出现周期性断连,"
    printf '%s\n' "    建议之后再用直连(不经过坞)的方式重测一轮作对比."
  fi
  if [ "${speed_num}" = "5" ]; then
    printf '%s\n' "⚠️  注意: 当前链路为 10Gbps 超高速档, 这正是老版本 USB 库无法识别的速率档,"
    printf '%s\n' "    是已知连接失败问题的触发条件之一 (详见测试结论)."
  fi
  printf '%s\n' "以上信息已存入 ${report}"
  printf '%s\n' ""
}


generate_usb_summary() {
  local scenario_dir="$1"
  local summary="${scenario_dir}/diagnosis-summary.txt"
  local link_report="${scenario_dir}/usb-link-report.txt"
  local mac_log="${scenario_dir}/files/handshaker-logs/usb-diagnostic.log"
  local android_log="${scenario_dir}/android/handshaker-usb-diagnostic.log"
  local timeline="${scenario_dir}/usb-enumeration-timeline.txt"
  local syslog="${scenario_dir}/system-log-usb.txt"
  local sample_dir="${scenario_dir}/samples"
  local aoa=0 mac_patch=0 mac_callsite_map=0 mac_handshake=0 mac_handshake_end=0
  local mac_handshake_failed=0 speed_unrecognized=0 link_superspeed=0
  local direct_out_wait=0 direct_in_wait=0
  local android_ready=0 accessory_intent=0 permission_requested=0 permission_granted=0 permission_denied=0
  local accessory_open=0 android_read_begin=0 android_read_end=0 android_write_end=0
  local evidence_complete=1 conclusion

  evidence_has '18[dD]1|2[dD]0[0-5]|idVendor[^0-9]*(6353)|idProduct[^0-9]*(1152[0-5])' "${timeline}" && aoa=1
  evidence_has 'event=PATCH_INSTALL handshake=1 callsiteMap=1' "${mac_log}" && mac_patch=1
  evidence_has 'event=HANDSHAKE_CALLSITE_MAP verified=1' "${mac_log}" && mac_callsite_map=1
  evidence_has 'event=HANDSHAKE_BEGIN' "${mac_log}" && mac_handshake=1
  evidence_has 'event=HANDSHAKE_END' "${mac_log}" && mac_handshake_end=1
  # HANDSHAKE_END is emitted for BOTH success and failure; the result field decides.
  evidence_has 'event=HANDSHAKE_END.*result=err:' "${mac_log}" && mac_handshake_failed=1
  # Bundled libusb 1.0.20 has no SuperSpeedPlus speed enum, so a 10Gbps link reports "Unknow"/speed=0.
  evidence_has 'Speed: Unknow|[^0-9]speed=0[^0-9]' "${mac_log}" && speed_unrecognized=1
  evidence_has 'enumerated .*(2[dD]0[0-5]).* at (10|20) Gbps' "${syslog}" && link_superspeed=1
  evidence_tree_has 'sendHandShakeRequestWithMSTimeout:\].*\+ (858|1018)([^0-9]|$)' "${sample_dir}" && direct_out_wait=1
  evidence_tree_has 'sendHandShakeRequestWithMSTimeout:\].*\+ (1580|2510)([^0-9]|$)' "${sample_dir}" && direct_in_wait=1
  evidence_has 'APP_START' "${android_log}" && android_ready=1
  evidence_has 'ACCESSORY_PERMISSION|ACTIVITY_NEW_INTENT.*USB_ACCESSORY_ATTACHED|SERVICE_ON_START.*UsbAccessory' "${android_log}" && accessory_intent=1
  evidence_has 'PERMISSION_REQUEST_SENT' "${android_log}" && permission_requested=1
  evidence_has 'ACCESSORY_PERMISSION hasPermission=true|PERMISSION_RESULT granted=true' "${android_log}" && permission_granted=1
  evidence_has 'PERMISSION_RESULT granted=false' "${android_log}" && permission_denied=1
  evidence_has 'OPEN_ACCESSORY_OK fd=' "${android_log}" && accessory_open=1
  evidence_has 'INPUT_FIRST_READ_BEGIN' "${android_log}" && android_read_begin=1
  evidence_has 'INPUT_FIRST_READ_END bytes=[1-9][0-9]*' "${android_log}" && android_read_end=1
  evidence_has 'OUTPUT_FIRST_WRITE_END bytes=[1-9][0-9]*' "${android_log}" && android_write_end=1

  if [ "${mac_handshake}" = "1" ]; then
    aoa=1
  fi
  if [ ! -f "${mac_log}" ] || [ ! -f "${android_log}" ] || [ "${mac_callsite_map}" = "0" ]; then
    evidence_complete=0
  fi

  if [ -f "${scenario_dir}/android/preflight-error.txt" ]; then
    conclusion="诊断前置检查未通过, 正式 USB 测试未开始. 请先解决摘要中的 ADB 或诊断 APK 问题."
    evidence_complete=0
  elif [ -f "${scenario_dir}/mac-preflight-error.txt" ]; then
    conclusion="Mac 诊断前置检查未通过, 正式 USB 测试未开始. 请重新安装包内 DMG 后再运行脚本."
    evidence_complete=0
  elif [ "${aoa}" = "0" ]; then
    conclusion="未进入 Android Open Accessory 模式. 故障位于线材, USB 端口, Mac 设备发现或 AOA 控制切换阶段."
  elif [ "${mac_patch}" = "0" ]; then
    conclusion="Mac 诊断补丁未加载, 本次证据不完整, 禁止据此判断 USB 根因."
    evidence_complete=0
  elif [ "${mac_handshake}" = "0" ]; then
    conclusion="设备已进入 AOA, 但 Mac 未开始应用层握手. 故障位于 SFUSBDevice 发现, 接口占用或握手调度阶段."
  elif [ "${android_ready}" = "0" ]; then
    conclusion="缺少 Android 持久日志, 本次证据不完整, 禁止据此判断 Android 是否收到 Accessory Intent."
    evidence_complete=0
  elif [ "${accessory_intent}" = "0" ]; then
    conclusion="Mac 已开始握手, 但 Android 未收到有效 Accessory Intent. 故障位于 Android Accessory Intent 分发或默认处理程序链路."
  elif [ "${permission_denied}" = "1" ]; then
    conclusion="Android 收到 Accessory Intent, 但 USB 配件权限被拒绝."
  elif [ "${permission_granted}" = "0" ]; then
    if [ "${permission_requested}" = "1" ]; then
      conclusion="Android 已发出 USB 配件权限请求, 但未收到授权结果. 故障位于系统授权弹窗或权限回调链路."
    else
      conclusion="Android 收到 Accessory Intent, 但没有进入授权完成路径. 故障位于 Android USB 权限流程."
    fi
  elif [ "${accessory_open}" = "0" ]; then
    conclusion="Android 已获得 USB 配件权限, 但 openAccessory 未成功返回文件描述符."
  elif [ "${android_read_begin}" = "0" ]; then
    conclusion="Android 已打开 Accessory, 但协议管线未进入首次 read. 故障位于 Android 协议线程启动阶段."
  elif [ "${android_read_end}" = "0" ]; then
    conclusion="Android 已等待首包但未收到数据. 故障位于 Mac 直接 libusb Bulk OUT 或主机到 Android 的 USB 数据交付链路, 不是相册索引或 Android 权限问题."
  elif [ "${android_write_end}" = "0" ]; then
    conclusion="Android 已收到 Mac 首包, 但未完成首次响应写入. 故障位于 Android SSP 响应生成或写线程."
  elif [ "${mac_handshake_failed}" = "1" ]; then
    if [ "${speed_unrecognized}" = "1" ] || [ "${link_superspeed}" = "1" ]; then
      conclusion="Mac 握手返回错误, 且链路以 SuperSpeedPlus (10Gbps) 枚举, 内置 libusb 1.0.20 无法识别该速率 (Speed: Unknow). 应改用 USB 3.0 (5Gbps) 级别数据线或 C-to-A 转接使链路降到 5Gbps 后重试; 5Gbps 链路实测可达 70MB/s 以上, 不影响传输速度. 应避免 USB 2.0 数据线, 实测会降至约 20MB/s."
    elif [ "${direct_out_wait}" = "1" ]; then
      conclusion="Mac 握手返回错误, 采样显示卡在直接 libusb Bulk OUT. 故障位于主机到设备的批量发送链路."
    elif [ "${direct_in_wait}" = "1" ]; then
      conclusion="Mac 握手返回错误, 采样显示卡在直接 libusb Bulk IN. 故障位于设备响应读取或解析链路."
    else
      conclusion="Mac 握手返回错误 (result=err), 但采样未命中具体 Bulk 调用点."
    fi
  elif [ "${mac_handshake_end}" = "0" ]; then
    conclusion="Android 已写出首次响应, 但 Mac 握手未返回. 故障位于 Mac 直接 libusb Bulk IN 或响应解析链路."
  else
    conclusion="双端首个读写均成功且 Mac 握手正常返回. USB 基础传输正常. 故障位于后续 SSP 握手或上层连接状态."
  fi

  {
    printf '结论: %s\n\n' "${conclusion}"
    printf '证据完整性: %s\n' "$([ "${evidence_complete}" = "1" ] && printf '完整' || printf '不完整')"
    if [ -f "${link_report}" ]; then
      printf '\n测试环境 (摘自 USB 链路预检):\n'
      sed -n '3,12p' "${link_report}" 2>/dev/null || true
      printf '\n'
    fi
    printf '测试时间: %s\n\n' "$(tr '\n' ' ' <"${scenario_dir}/test-window.txt" 2>/dev/null || true)"
    printf '关键路径:\n'
    printf -- '- AOA 枚举: %s\n' "${aoa}"
    printf -- '- Mac 诊断补丁: %s\n' "${mac_patch}"
    printf -- '- Mac 直接 Bulk 调用点校验: %s\n' "${mac_callsite_map}"
    printf -- '- Mac 握手开始: %s\n' "${mac_handshake}"
    printf -- '- Mac 握手返回: %s\n' "${mac_handshake_end}"
    printf -- '- Mac 握手返回错误: %s\n' "${mac_handshake_failed}"
    printf -- '- 链路以 10Gbps 及以上枚举: %s\n' "${link_superspeed}"
    printf -- '- libusb 无法识别链路速率: %s\n' "${speed_unrecognized}"
    printf -- '- 采样命中直接 Bulk OUT/IN: %s/%s\n' "${direct_out_wait}" "${direct_in_wait}"
    printf -- '- Android 诊断启动: %s\n' "${android_ready}"
    printf -- '- Android Accessory Intent: %s\n' "${accessory_intent}"
    printf -- '- Android 权限请求/授权/拒绝: %s/%s/%s\n' "${permission_requested}" "${permission_granted}" "${permission_denied}"
    printf -- '- Android openAccessory: %s\n' "${accessory_open}"
    printf -- '- Android 首次 read 开始/收到数据: %s/%s\n' "${android_read_begin}" "${android_read_end}"
    printf -- '- Android 首次 write 完成: %s\n\n' "${android_write_end}"
    printf '原始证据: files/handshaker-logs/usb-diagnostic.log, android/handshaker-usb-diagnostic.log, android/logcat-full.txt, samples/, usb-enumeration-timeline.txt, system-log-usb.txt.\n'
  } >"${summary}"
}

run_usb_summary_self_test() {
  local root
  root="$(mktemp -d "${TMPDIR:-/tmp}/handshaker-diagnostics-test.XXXXXX")" || return 1
  mkdir -p "${root}/files/handshaker-logs" "${root}/android" "${root}/samples"
  printf '%s\n' \
    'event=HANDSHAKE_CALLSITE_MAP verified=1' \
    'event=PATCH_INSTALL handshake=1 callsiteMap=1' \
    'session=test event=HANDSHAKE_BEGIN' \
    >"${root}/files/handshaker-logs/usb-diagnostic.log"
  printf '%s\n' \
    'APP_START' \
    'ACCESSORY_PERMISSION hasPermission=true' \
    'OPEN_ACCESSORY_OK fd=42' \
    'INPUT_FIRST_READ_BEGIN requested=16' \
    >"${root}/android/handshaker-usb-diagnostic.log"
  printf '%s\n' '-[SFUSBDevice sendHandShakeRequestWithMSTimeout:] (in SmartFinderCore) + 858' >"${root}/samples/sample-001.txt"
  printf '%s\n' 'idVendor = 6353 idProduct = 11521' >"${root}/usb-enumeration-timeline.txt"
  printf '%s\n' 'start=self-test' 'end=self-test' >"${root}/test-window.txt"

  generate_usb_summary "${root}"
  if ! grep -q 'libusb Bulk OUT' "${root}/diagnosis-summary.txt"; then
    cat "${root}/diagnosis-summary.txt"
    rm -rf "${root}"
    return 1
  fi
  rm -rf "${root}"

  # Regression case: every stage reports success but the handshake actually
  # returned "err: Operation timed out" on a 10Gbps link. This previously
  # produced the wrong "USB 基础传输正常" verdict.
  root="$(mktemp -d "${TMPDIR:-/tmp}/handshaker-diagnostics-test.XXXXXX")" || return 1
  mkdir -p "${root}/files/handshaker-logs" "${root}/android" "${root}/samples"
  printf '%s\n' \
    'event=HANDSHAKE_CALLSITE_MAP verified=1' \
    'event=PATCH_INSTALL handshake=1 callsiteMap=1' \
    'session=test event=HANDSHAKE_BEGIN Speed: Unknow speed=0' \
    'session=test event=HANDSHAKE_END elapsedMs=15213 resultPresent=1 result=err: Operation timed out Speed: Unknow speed=0' \
    >"${root}/files/handshaker-logs/usb-diagnostic.log"
  printf '%s\n' \
    'APP_START' \
    'ACCESSORY_PERMISSION hasPermission=true' \
    'OPEN_ACCESSORY_OK fd=144' \
    'INPUT_FIRST_READ_BEGIN requested=16384' \
    'INPUT_FIRST_READ_END bytes=217 elapsedMs=1' \
    'OUTPUT_FIRST_WRITE_END bytes=189 elapsedMs=1' \
    >"${root}/android/handshaker-usb-diagnostic.log"
  printf '%s\n' '-[SFUSBDevice sendHandShakeRequestWithMSTimeout:] (in SmartFinderCore) + 858' >"${root}/samples/sample-001.txt"
  printf '%s\n' 'idVendor = 6353 idProduct = 11521' >"${root}/usb-enumeration-timeline.txt"
  printf '%s\n' 'enumerated 0x18d1/2d01/0515 (Xiaomi 13 Ultra / 1) at 10 Gbps' >"${root}/system-log-usb.txt"
  printf '%s\n' 'start=self-test' 'end=self-test' >"${root}/test-window.txt"

  generate_usb_summary "${root}"
  if grep -q 'USB 基础传输正常' "${root}/diagnosis-summary.txt" || ! grep -q 'SuperSpeedPlus' "${root}/diagnosis-summary.txt"; then
    cat "${root}/diagnosis-summary.txt"
    rm -rf "${root}"
    return 1
  fi
  rm -rf "${root}"
  printf '%s\n' "USB diagnosis summary self-test passed"
}


# 断连观察窗: 回车结束后继续监测 usb-enumeration-timeline 是否仍在变化.
# 任何新出现的设备增删都会延长观察; 连续 30 秒无变化或到达 max_seconds 结束.
observe_disconnect_window() {
  local scenario_dir="$1"
  local usb_stop_file="$2"
  local max_seconds="${3:-300}"
  local timeline="${scenario_dir}/usb-enumeration-timeline.txt"
  local last_size quiet_seconds=0

  [ -f "${timeline}" ] || return 0

  while [ "${max_seconds}" -gt 0 ]; do
    sleep 5
    [ -f "${usb_stop_file}" ] && break
    local current_size
    current_size="$(wc -c <"${timeline}" 2>/dev/null | tr -d ' ')"
    if [ "${current_size}" != "${last_size:-}" ]; then
      if [ -n "${last_size:-}" ]; then
        printf '  %s\n' "$(date '+%H:%M:%S') USB 设备状态发生变化（可能是断连/重连），继续观察..."
      fi
      last_size="${current_size}"
      quiet_seconds=0
    else
      quiet_seconds=$((quiet_seconds + 5))
      if [ "${quiet_seconds}" -ge 30 ]; then
        printf '%s\n' "  链路已稳定 30 秒，观察结束。"
        return 0
      fi
    fi
    max_seconds=$((max_seconds - 5))
  done
  printf '%s\n' "  观察窗口达到上限，结束。"
}

collect_usb() {
  local scenario_dir="${out_dir}/usb"
  local stop_file="${scenario_dir}/.stop-sampling"
  local usb_stop_file="${scenario_dir}/.stop-usb-monitor"
  local mac_usb_log_dir="${HOME}/Library/Application Support/HandShaker/logs"
  local mac_usb_log="${mac_usb_log_dir}/usb-diagnostic.log"
  local log_start log_end patch_ready=0

  mkdir -p "${scenario_dir}"
  rm -f "${stop_file}" "${usb_stop_file}"

  say_step "USB 诊断"
  printf '%s\n' "正式测试前会先验证 Android 诊断日志. 前置检查不通过时不会开始测试，避免白测一次."
  printf '%s\n' "1. 先把手机连接到这台 Mac, 开启 USB 调试并允许这台 Mac."
  printf '%s\n' "2. 脚本会自动安装同包内诊断版 Android HandShaker, 保留应用数据."
  printf '%s\n' "3. 前置检查完成后再按提示拔线, 正式测试只需插线一次."
  close_handshaker || return 0
  press_enter "手机已连接并允许 USB 调试后按回车开始前置检查..."

  if ! prepare_android_usb_diagnostics "${scenario_dir}"; then
    printf '%s\n' "status=not-started reason=android-preflight-failed" >"${scenario_dir}/test-window.txt"
    generate_usb_summary "${scenario_dir}"
    return 0
  fi

  printf '%s\n' "Android 诊断日志验证通过."
  printf '%s\n' ""
  print_usb_link_report "${scenario_dir}"
  press_enter "现在拔下手机数据线, 拔下后按回车准备正式测试..."

  mkdir -p "${mac_usb_log_dir}"
  if [ -f "${mac_usb_log}" ]; then
    cp -p "${mac_usb_log}" "${scenario_dir}/preexisting-mac-usb-diagnostic.log"
  fi
  rm -f "${mac_usb_log}" "${mac_usb_log}.previous"
  if [ -e "${mac_usb_log}" ]; then
    printf '%s\n' "无法清空 Mac 旧诊断日志, 正式测试不会开始." | tee "${scenario_dir}/mac-preflight-error.txt"
    printf '%s\n' "status=not-started reason=mac-diagnostic-log-reset-failed" >"${scenario_dir}/test-window.txt"
    generate_usb_summary "${scenario_dir}"
    return 0
  fi
  capture_usb_snapshot "${scenario_dir}" "before"
  log_start="$(date -v-10S '+%Y-%m-%d %H:%M:%S')"
  start_log_monitor "${scenario_dir}" "usb"
  open_handshaker || {
    stop_log_monitor "${log_monitor_pid}"
    printf '%s\n' "status=not-started reason=mac-app-start-failed" >"${scenario_dir}/test-window.txt"
    generate_usb_summary "${scenario_dir}"
    return 0
  }

  if ! wait_for_handshaker; then
    printf '%s\n' "没有找到 HandShaker 进程." >"${scenario_dir}/error.txt"
    stop_log_monitor "${log_monitor_pid}"
    printf '%s\n' "status=not-started reason=mac-process-not-found" >"${scenario_dir}/test-window.txt"
    generate_usb_summary "${scenario_dir}"
    return 0
  fi

  for _ in {1..40}; do
    if [ -f "${mac_usb_log}" ] && \
       grep -q 'event=HANDSHAKE_CALLSITE_MAP verified=1' "${mac_usb_log}" 2>/dev/null && \
       grep -q 'event=PATCH_INSTALL handshake=1 callsiteMap=1' "${mac_usb_log}" 2>/dev/null; then
      patch_ready=1
      break
    fi
    sleep 0.25
  done
  if [ "${patch_ready}" != "1" ]; then
    printf '%s\n' "Mac USB 诊断补丁未加载, 正式测试不会开始." | tee "${scenario_dir}/mac-preflight-error.txt"
    stop_log_monitor "${log_monitor_pid}"
    close_handshaker || true
    collect_handshaker_files "${scenario_dir}"
    printf '%s\n' "status=not-started reason=mac-diagnostic-patch-missing" >"${scenario_dir}/test-window.txt"
    generate_usb_summary "${scenario_dir}"
    return 0
  fi

  capture_app_state "${scenario_dir}" "before-repro"
  start_sampler "${scenario_dir}" "${stop_file}"
  start_usb_monitor "${scenario_dir}" "${usb_stop_file}"
  {
    printf 'start_local=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf 'start_epoch=%s\n' "$(date '+%s')"
  } >"${scenario_dir}/test-window.txt"
  printf '%s\n' "现在把手机数据线插到 Mac 上（只插这一次，不要反复插拔）。"
  printf '%s\n' "插上后手机会弹出“允许 USB 配件”的弹窗，像平时那样点允许。"
  printf '%s\n' "然后等手机或 Mac 出现连接结果（连上或失败都算）——最多等 30 秒。"
  printf '%s\n' ""
  printf '%s\n' "连接成功后请像平时一样继续使用 1-2 分钟（浏览/传输文件都可以）。"
  printf '%s\n' "如果中途出现断连/掉线，请等它自动重连（或重新插一次线）后继续等待。"
  press_enter "现象出现后（或正常使用满 2 分钟无异常），回到这里按回车结束采集..."
  {
    printf 'end_local=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf 'end_epoch=%s\n' "$(date '+%s')"
  } >>"${scenario_dir}/test-window.txt"

  # 断连观察窗: 采集结束后自动继续监测一段, 覆盖"回车后 1-2 分钟才断连"的场景.
  # 观察到 USB 设备增删变化则持续延长, 直到链路稳定 30 秒或达到上限.
  if grep -q '0x18d1\|2D01' "${scenario_dir}/usb-enumeration-timeline.txt" 2>/dev/null; then
    printf '%s\n' ""
    printf '%s\n' "正在追加观察窗口（检测连接是否会在稍后自动断开）..."
    observe_disconnect_window "${scenario_dir}" "${usb_stop_file}" 300
  fi
  screencapture -x "${scenario_dir}/mac-screen-after-repro.png" >/dev/null 2>&1 || true
  capture_app_state "${scenario_dir}" "after-repro"
  stop_sampler "${sampler_pid}" "${stop_file}"
  stop_usb_monitor "${usb_monitor_pid}" "${usb_stop_file}"
  stop_log_monitor "${log_monitor_pid}"

  capture_sample "${scenario_dir}" "final"
  capture_usb_snapshot "${scenario_dir}" "after"
  log_end="$(date '+%Y-%m-%d %H:%M:%S')"
  /usr/bin/log show --style syslog --start "${log_start}" --end "${log_end}" --predicate 'process == "HandShaker" OR eventMessage CONTAINS[c] "HandShaker" OR eventMessage CONTAINS[c] "HandShakerMaintained" OR eventMessage CONTAINS[c] "SmartFinder" OR eventMessage CONTAINS[c] "USBHost" OR eventMessage CONTAINS[c] "libusb" OR eventMessage CONTAINS[c] "Accessory" OR eventMessage CONTAINS[c] "AOA" OR eventMessage CONTAINS[c] "Android" OR eventMessage CONTAINS[c] "Xiaomi" OR eventMessage CONTAINS[c] "Smartisan"' >"${scenario_dir}/system-log-usb.txt" 2>&1
  diff -u "${scenario_dir}/ioreg-usb-before.txt" "${scenario_dir}/ioreg-usb-after.txt" >"${scenario_dir}/ioreg-usb-diff.txt" 2>&1 || true
  diff -u "${scenario_dir}/ioreg-usbhost-before.txt" "${scenario_dir}/ioreg-usbhost-after.txt" >"${scenario_dir}/ioreg-usbhost-diff.txt" 2>&1 || true
  collect_handshaker_files "${scenario_dir}"
  collect_android_usb_evidence "${scenario_dir}" || true
  generate_usb_summary "${scenario_dir}"
  ask_choice "${scenario_dir}/user-result.txt" \
    "请选择这次 USB 测试结果:" \
    "1. 手机和 Mac 都没反应" \
    "2. 手机显示已连接, Mac 仍未连接" \
    "3. Mac 显示已连接" \
    "4. Mac 转彩球或卡死"
}

collect_wifi() {
  local scenario_dir="${out_dir}/wifi"
  local stop_file="${scenario_dir}/.stop-sampling"
  local bonjour_stop_file="${scenario_dir}/.stop-bonjour-monitor"

  mkdir -p "${scenario_dir}"
  rm -f "${stop_file}" "${bonjour_stop_file}"

  say_step "Wi-Fi 诊断"
  printf '%s\n' "1. 确认手机和 Mac 连接同一个 Wi-Fi."
  printf '%s\n' "2. 按回车后, 我会打开 HandShaker 并开始采样."
  printf '%s\n' "3. 然后你按平时方式尝试 Wi-Fi 连接或扫码."
  printf '%s\n' "4. 如果 Mac 转彩球或连接失败, 回到这个窗口按回车结束 Wi-Fi 采集."
  press_enter "准备好后按回车开始 Wi-Fi 诊断..."

  run_capture "${scenario_dir}/network-hardware.txt" networksetup -listallhardwareports
  run_capture "${scenario_dir}/network-route.txt" route -n get default
  run_capture "${scenario_dir}/ifconfig.txt" ifconfig
  run_capture "${scenario_dir}/dns.txt" scutil --dns
  run_capture "${scenario_dir}/arp-before.txt" arp -a
  open_handshaker || return 0

  if ! wait_for_handshaker; then
    printf '%s\n' "没有找到 HandShaker 进程." >"${scenario_dir}/error.txt"
    return 0
  fi

  capture_app_state "${scenario_dir}" "before-repro"
  start_log_monitor "${scenario_dir}" "wifi"
  start_sampler "${scenario_dir}" "${stop_file}"
  start_bonjour_monitor "${scenario_dir}" "${bonjour_stop_file}"
  press_enter "现在照平时的方式连接 Wi-Fi（出现平时的问题后）——最多等 30 秒，然后回到这里按回车..."
  screencapture -x "${scenario_dir}/mac-screen-after-repro.png" >/dev/null 2>&1 || true
  capture_app_state "${scenario_dir}" "after-repro"
  stop_sampler "${sampler_pid}" "${stop_file}"
  stop_bonjour_monitor "${bonjour_monitor_pid}" "${bonjour_stop_file}"
  stop_log_monitor "${log_monitor_pid}"

  capture_sample "${scenario_dir}" "final"
  run_capture "${scenario_dir}/arp-after.txt" arp -a
  /usr/bin/log show --style syslog --last 30m --predicate 'process == "HandShaker" OR eventMessage CONTAINS[c] "HandShaker" OR eventMessage CONTAINS[c] "HandShakerMaintained" OR eventMessage CONTAINS[c] "SmartFinder" OR eventMessage CONTAINS[c] "Local Network" OR eventMessage CONTAINS[c] "Bonjour" OR eventMessage CONTAINS[c] "_handshaker_ssp" OR eventMessage CONTAINS[c] "nw_connection"' >"${scenario_dir}/system-log-wifi.txt" 2>&1
  collect_handshaker_files "${scenario_dir}"
  ask_choice "${scenario_dir}/user-result.txt" \
    "请选择这次 Wi-Fi 测试结果:" \
    "1. 搜不到手机" \
    "2. 卡在等待信任" \
    "3. 连接成功, 没有转彩球" \
    "4. 连接成功后转彩球或卡死"
}

if [ "${1:-}" = "--self-test" ]; then
  run_usb_summary_self_test
  exit $?
fi

mkdir -p "${common_dir}"

say_step "HandShaker 诊断工具"
printf '%s\n' "这个窗口不要关闭. 诊断结束后, 桌面会生成一个 zip 文件."
if ! find_app; then
  printf '%s\n' "未找到 /Applications/HandShaker.app."
  printf '%s\n' "请先打开测试包中的 DMG, 将 HandShaker 拖入应用程序文件夹, 再运行本脚本."
  press_enter "按回车退出..."
  exit 1
fi
printf '\n%s\n' "请选择要收集的日志:"
printf '%s\n' "1. 只收集 USB"
printf '%s\n' "2. 只收集 Wi-Fi"
printf '%s\n' "3. USB 和 Wi-Fi 都收集"
printf '%s' "输入 1, 2 或 3 后按回车: "
read -r choice

collect_common

case "${choice}" in
  1)
    collect_usb
    ;;
  2)
    collect_wifi
    ;;
  3)
    collect_usb
    collect_wifi
    ;;
  *)
    printf '%s\n' "无效选择: ${choice}"
    exit 1
    ;;
esac

zip_path="${out_dir}.zip"
ditto -c -k --keepParent "${out_dir}" "${zip_path}"

say_step "诊断完成"
printf '请把这个文件发给维护者: %s\n' "${zip_path}"
open -R "${zip_path}"
