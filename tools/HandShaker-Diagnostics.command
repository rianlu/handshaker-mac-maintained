#!/bin/zsh

set -u

timestamp="$(date '+%Y%m%d-%H%M%S')"
out_dir="${HOME}/Desktop/HandShaker-Diagnostics-${timestamp}"
common_dir="${out_dir}/common"
app_name="HandShaker"
app_path="/Applications/HandShaker.app"
app_executable="${app_path}/Contents/MacOS/HandShaker"
sampler_pid=""
usb_monitor_pid=""
bonjour_monitor_pid=""
log_monitor_pid=""

mkdir -p "${common_dir}"

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

find_app() {
  [ -d "${app_path}" ]
}

open_handshaker() {
  if ! find_app; then
    printf '%s\n' "未找到 /Applications/HandShaker.app. 请先打开 DMG, 将 HandShaker 拖入应用程序文件夹." | tee "${common_dir}/app-not-found.txt"
    return 1
  fi

  if pgrep -x "${app_name}" >/dev/null 2>&1; then
    osascript -e 'tell application "HandShaker" to quit' >/dev/null 2>&1 || true
    for _ in {1..50}; do
      pgrep -x "${app_name}" >/dev/null 2>&1 || break
      sleep 0.1
    done
  fi

  if pgrep -x "${app_name}" >/dev/null 2>&1; then
    printf '%s\n' "无法正常关闭正在运行的 HandShaker. 请手动退出后重新运行诊断脚本." | tee "${common_dir}/app-still-running.txt"
    return 1
  fi

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
  /usr/bin/sample "${pid}" 10 -file "${scenario_dir}/samples/sample-${label}.txt" >"${scenario_dir}/samples/sample-${label}.stderr.txt" 2>&1
}

start_sampler() {
  local scenario_dir="$1"
  local stop_file="$2"
  local index=1

  (
    while [ ! -f "${stop_file}" ]; do
      capture_sample "${scenario_dir}" "$(printf '%03d' "${index}")"
      index=$((index + 1))
      sleep 10
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
  local index=1

  (
    while [ ! -f "${stop_file}" ]; do
      run_capture "${scenario_dir}/ioreg-usb-$(printf '%03d' "${index}").txt" ioreg -p IOUSB -l -w0
      index=$((index + 1))
      sleep 5
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

collect_usb() {
  local scenario_dir="${out_dir}/usb"
  local stop_file="${scenario_dir}/.stop-sampling"
  local usb_stop_file="${scenario_dir}/.stop-usb-monitor"

  mkdir -p "${scenario_dir}"
  rm -f "${stop_file}" "${usb_stop_file}"

  say_step "USB 诊断"
  printf '%s\n' "重要: 测试时请同时看手机 HandShaker 页面底部 USB 状态流水."
  printf '%s\n' "如果状态停住或连接成功, 请拍一张手机页面照片, 和 zip 一起发给维护者."
  printf '%s\n' "1. 先拔掉手机 USB 线."
  printf '%s\n' "2. 按回车后, 我会打开 HandShaker 并开始采样."
  printf '%s\n' "3. 然后你插上手机, 按平时方式允许弹窗."
  printf '%s\n' "4. 如果 Mac 转彩球, 不要强退, 等 30 秒后回到这个窗口按回车."
  printf '%s\n' "5. 出现未连接或连接成功后, 回到这个窗口按回车结束 USB 采集."
  press_enter "准备好后按回车开始 USB 诊断..."

  printf '%s\n' "请拍摄手机 HandShaker USB 状态流水页面, 和本 zip 一起发送." >"${scenario_dir}/android-usb-status-photo-required.txt"
  capture_usb_snapshot "${scenario_dir}" "before"
  start_log_monitor "${scenario_dir}" "usb"
  open_handshaker || {
    stop_log_monitor "${log_monitor_pid}"
    return 0
  }

  if ! wait_for_handshaker; then
    printf '%s\n' "没有找到 HandShaker 进程." >"${scenario_dir}/error.txt"
    stop_log_monitor "${log_monitor_pid}"
    return 0
  fi

  capture_app_state "${scenario_dir}" "before-repro"
  start_sampler "${scenario_dir}" "${stop_file}"
  start_usb_monitor "${scenario_dir}" "${usb_stop_file}"
  press_enter "现在请插上手机并复现 USB 问题. 复现后按回车结束 USB 采集..."
  screencapture -x "${scenario_dir}/mac-screen-after-repro.png" >/dev/null 2>&1 || true
  capture_app_state "${scenario_dir}" "after-repro"
  stop_sampler "${sampler_pid}" "${stop_file}"
  stop_usb_monitor "${usb_monitor_pid}" "${usb_stop_file}"
  stop_log_monitor "${log_monitor_pid}"

  capture_sample "${scenario_dir}" "final"
  capture_usb_snapshot "${scenario_dir}" "after"
  /usr/bin/log show --style syslog --last 30m --predicate 'process == "HandShaker" OR eventMessage CONTAINS[c] "HandShaker" OR eventMessage CONTAINS[c] "HandShakerMaintained" OR eventMessage CONTAINS[c] "SmartFinder" OR eventMessage CONTAINS[c] "USBHost" OR eventMessage CONTAINS[c] "libusb" OR eventMessage CONTAINS[c] "Accessory" OR eventMessage CONTAINS[c] "AOA" OR eventMessage CONTAINS[c] "Android" OR eventMessage CONTAINS[c] "Xiaomi" OR eventMessage CONTAINS[c] "Smartisan"' >"${scenario_dir}/system-log-usb.txt" 2>&1
  diff -u "${scenario_dir}/ioreg-usb-before.txt" "${scenario_dir}/ioreg-usb-after.txt" >"${scenario_dir}/ioreg-usb-diff.txt" 2>&1 || true
  diff -u "${scenario_dir}/ioreg-usbhost-before.txt" "${scenario_dir}/ioreg-usbhost-after.txt" >"${scenario_dir}/ioreg-usbhost-diff.txt" 2>&1 || true
  collect_handshaker_files "${scenario_dir}"
  ask_text "${scenario_dir}/android-usb-status-text.txt" "请把手机 HandShaker 页面底部最后显示的 USB 状态文字输入到这里:"
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
  press_enter "现在请复现 Wi-Fi 问题. 复现后按回车结束 Wi-Fi 采集..."
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
