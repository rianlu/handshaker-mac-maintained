#!/bin/zsh

set -u

timestamp="$(date '+%Y%m%d-%H%M%S')"
out_dir="${HOME}/Desktop/HandShaker-Diagnostics-${timestamp}"
common_dir="${out_dir}/common"
app_name="HandShaker"
app_path=""
sampler_pid=""
usb_monitor_pid=""
bonjour_monitor_pid=""

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
  local script_dir candidate
  script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"

  for candidate in \
    "${script_dir}/HandShaker.app" \
    "${script_dir}/../HandShaker.app" \
    "/Applications/HandShaker.app"
  do
    if [ -d "${candidate}" ]; then
      app_path="${candidate}"
      return 0
    fi
  done

  return 1
}

open_handshaker() {
  if find_app; then
    open "${app_path}"
  else
    printf '%s\n' "HandShaker.app not found. Please keep this script next to HandShaker.app." | tee "${common_dir}/app-not-found.txt"
    return 1
  fi
}

find_pid() {
  pgrep -x "${app_name}" | head -n 1
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
  run_capture "${output_dir}/vmmap-summary-${label}.txt" vmmap -summary "${pid}"
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
  sample "${pid}" 5 -file "${scenario_dir}/samples/sample-${label}.txt" >"${scenario_dir}/samples/sample-${label}.stderr.txt" 2>&1
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

start_bonjour_monitor() {
  local scenario_dir="$1"
  local stop_file="$2"

  (
    while [ ! -f "${stop_file}" ]; do
      date
      dns-sd -B _handshaker_ssp._tcp local &
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

  if find_app; then
    run_capture "${common_dir}/security-assessment.txt" spctl --assess --type execute --verbose=4 "${app_path}"
    run_capture "${common_dir}/app-codesign.txt" codesign -dv --verbose=4 "${app_path}"
    run_capture "${common_dir}/app-info-plist.txt" plutil -p "${app_path}/Contents/Info.plist"
  else
    printf '%s\n' "HandShaker.app not found next to this script or in /Applications." >"${common_dir}/app-not-found.txt"
  fi
}

collect_usb() {
  local scenario_dir="${out_dir}/usb"
  local stop_file="${scenario_dir}/.stop-sampling"
  local usb_stop_file="${scenario_dir}/.stop-usb-monitor"

  mkdir -p "${scenario_dir}"
  rm -f "${stop_file}" "${usb_stop_file}"

  say_step "USB 诊断"
  printf '%s\n' "1. 先拔掉手机 USB 线."
  printf '%s\n' "2. 按回车后, 我会打开 HandShaker 并开始采样."
  printf '%s\n' "3. 然后你插上手机, 按平时方式允许弹窗."
  printf '%s\n' "4. 出现未连接或连接成功后, 回到这个窗口按回车结束 USB 采集."
  press_enter "准备好后按回车开始 USB 诊断..."

  run_capture "${scenario_dir}/usb-before.txt" system_profiler SPUSBDataType
  run_capture "${scenario_dir}/ioreg-usb-before.txt" ioreg -p IOUSB -l -w0
  open_handshaker || return 0

  if ! wait_for_handshaker; then
    printf '%s\n' "没有找到 HandShaker 进程." >"${scenario_dir}/error.txt"
    return 0
  fi

  capture_app_state "${scenario_dir}" "before-repro"
  start_sampler "${scenario_dir}" "${stop_file}"
  start_usb_monitor "${scenario_dir}" "${usb_stop_file}"
  press_enter "现在请插上手机并复现 USB 问题. 复现后按回车结束 USB 采集..."
  capture_app_state "${scenario_dir}" "after-repro"
  stop_sampler "${sampler_pid}" "${stop_file}"
  stop_usb_monitor "${usb_monitor_pid}" "${usb_stop_file}"

  capture_sample "${scenario_dir}" "final"
  run_capture "${scenario_dir}/usb-after.txt" system_profiler SPUSBDataType
  run_capture "${scenario_dir}/ioreg-usb-after.txt" ioreg -p IOUSB -l -w0
  /usr/bin/log show --style syslog --last 45m --predicate 'process == "HandShaker" OR eventMessage CONTAINS[c] "HandShaker" OR eventMessage CONTAINS[c] "USB" OR eventMessage CONTAINS[c] "IOUSB" OR eventMessage CONTAINS[c] "libusb" OR eventMessage CONTAINS[c] "Accessory"' >"${scenario_dir}/system-log-usb.txt" 2>&1
  diff -u "${scenario_dir}/ioreg-usb-before.txt" "${scenario_dir}/ioreg-usb-after.txt" >"${scenario_dir}/ioreg-usb-diff.txt" 2>&1 || true
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
  start_sampler "${scenario_dir}" "${stop_file}"
  start_bonjour_monitor "${scenario_dir}" "${bonjour_stop_file}"
  press_enter "现在请复现 Wi-Fi 问题. 复现后按回车结束 Wi-Fi 采集..."
  capture_app_state "${scenario_dir}" "after-repro"
  stop_sampler "${sampler_pid}" "${stop_file}"
  stop_bonjour_monitor "${bonjour_monitor_pid}" "${bonjour_stop_file}"

  capture_sample "${scenario_dir}" "final"
  run_capture "${scenario_dir}/arp-after.txt" arp -a
  /usr/bin/log show --style syslog --last 45m --predicate 'process == "HandShaker" OR process == "mDNSResponder" OR eventMessage CONTAINS[c] "HandShaker" OR eventMessage CONTAINS[c] "Local Network" OR eventMessage CONTAINS[c] "Bonjour" OR eventMessage CONTAINS[c] "_handshaker_ssp" OR eventMessage CONTAINS[c] "nw_connection"' >"${scenario_dir}/system-log-wifi.txt" 2>&1
  ask_choice "${scenario_dir}/user-result.txt" \
    "请选择这次 Wi-Fi 测试结果:" \
    "1. 搜不到手机" \
    "2. 卡在等待信任" \
    "3. 连接成功, 没有转彩球" \
    "4. 连接成功后转彩球或卡死"
}

say_step "HandShaker 诊断工具"
printf '%s\n' "这个窗口不要关闭. 诊断结束后, 桌面会生成一个 zip 文件."
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
