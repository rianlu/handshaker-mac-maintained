#!/bin/bash
# Execute under the macOS system Bash, including when invoked with sh or zsh.
if [ -z "${BASH_VERSION:-}" ]; then exec /bin/bash "$0" "$@"; fi
if shopt -oq posix; then exec /bin/bash "$0" "$@"; fi
set -u
set -o pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
script_revision="20260909-flow5"
app_path="${HANDSHAKER_DIAGNOSTIC_APP_PATH:-/Applications/HandShaker.app}"
app_executable="${app_path}/Contents/MacOS/HandShaker"
android_package="com.smartisanos.smartfolder.aoa"
diagnostic_apk="${script_dir}/HandShaker-Android-USB-Diagnostic.apk"
adb_path=""; adb_serial=""; android_user=""; android_external_dir=""; usb_location=""
out_dir=""; state_dir=""; run_id=""; scenario_dir=""; mac_pid=""
workflow_result="not-started"; finalized=0
lock_dir=""; lock_held=0; test_file=""
mac_takeover=0; mac_close_sequence=0; cleanup_result="not-needed"
worker_pids=()

step() { printf '\n------------------------------------------------------------\n[%s] %s\n------------------------------------------------------------\n' "$1" "$2"; }
info() { printf '  %s\n' "$*"; }
prompt_enter() {
  printf '\n现在请操作: %s\n完成后按回车继续, 或输入 Q 保存日志并结束: ' "$1"
  if ! IFS= read -r answer; then return 130; fi
  case "$answer" in q|Q) return 130 ;; esac
}
choice() {
  local output="$1" title="$2" allowed="$3" answer
  shift 3
  while :; do
    printf '\n%s\n' "$title"
    printf '  %s\n' "$@"
    printf '请输入数字, 再按回车: '
    IFS= read -r answer || return 130
    case "$answer" in q|Q) return 130 ;; esac
    case ",${allowed}," in
      *",${answer},"*) if [ -n "$answer" ]; then printf '%s\n' "$answer" >"$output"; return 0; fi ;;
    esac
    info "没有识别到选项. 请只输入上面列出的一个数字."
  done
}
acquire_run_lock() {
  local owner_pid owner_start actual_start
  lock_dir="${TMPDIR:-/tmp}/HandShaker-Diagnostics-$EUID.lock"
  if ! mkdir "$lock_dir" 2>/dev/null; then
    if [ -L "$lock_dir" ] || [ "$(stat -f '%u' "$lock_dir" 2>/dev/null)" != "$EUID" ]; then
      info "无法取得本轮运行锁. 请回传此提示, 不要重复打开脚本."; return 1
    fi
    owner_pid=$(sed -n '1p' "$lock_dir/owner.txt" 2>/dev/null)
    owner_start=$(sed -n '2p' "$lock_dir/owner.txt" 2>/dev/null)
    case "$owner_pid" in ''|*[!0-9]*) info "另一个测试窗口正在初始化. 请使用原窗口, 稍后再试."; return 1 ;; esac
    actual_start=$(ps -p "$owner_pid" -o lstart= 2>/dev/null || true)
    if [ -n "$actual_start" ] && [ "$actual_start" = "$owner_start" ]; then
      info "已有一轮测试正在运行. 请回到原来的终端窗口, 本窗口不会再启动测试."
      [ ! -f "$lock_dir/output.txt" ] || { info "原测试的日志目录:"; cat "$lock_dir/output.txt"; }
      return 1
    fi
    rm -f "$lock_dir/owner.txt" "$lock_dir/output.txt"
    rmdir "$lock_dir" 2>/dev/null && mkdir "$lock_dir" 2>/dev/null || return 1
  fi
  { printf '%s\n' "$$"; ps -p "$$" -o lstart=; } >"$lock_dir/owner.txt"
  lock_held=1
}
release_run_lock() {
  [ "$lock_held" = 1 ] || return 0
  if [ "$(sed -n '1p' "$lock_dir/owner.txt" 2>/dev/null)" = "$$" ]; then
    rm -f "$lock_dir/owner.txt" "$lock_dir/output.txt"
    rmdir "$lock_dir" 2>/dev/null || true
  fi
  lock_held=0
}
manifest_value() {
  [ -f "$script_dir/diagnostic-manifest.txt" ] || return 0
  awk -v key="$1" 'index($0, key "=")==1 {print substr($0, length(key)+2); exit}' "$script_dir/diagnostic-manifest.txt"
}
terminate_tree() {
  local target="$1" child
  case "$target" in ''|0|1|*[!0-9]*) return ;; esac
  # Freeze only our own collector before enumerating its descendants.
  kill -STOP "$target" 2>/dev/null || return 0
  for child in $(pgrep -P "$target" 2>/dev/null || true); do terminate_tree "$child"; done
  kill -TERM "$target" 2>/dev/null || true
  kill -CONT "$target" 2>/dev/null || true
  kill -KILL "$target" 2>/dev/null || true
}
# Preserve raw output separately from command, exit status and timeout metadata.
run_capture() {
  local output="$1" limit="$2" captured_pid timer_pid command_result started finished
  shift 2
  mkdir -p "$(dirname "$output")"
  rm -f "${output}.timeout"
  started=$(date +%s)
  printf 'command=' >"${output}.meta"
  printf '%q ' "$@" >>"${output}.meta"
  printf '\nstart_epoch=%s\nlimit_seconds=%s\n' "$started" "$limit" >>"${output}.meta"
  "$@" >"$output" 2>&1 &
  captured_pid=$!
  [ -z "$state_dir" ] || : >"$state_dir/children/$captured_pid"
  timer_pid=""
  if [ "$limit" -gt 0 ]; then
    (
      trap - EXIT INT TERM HUP
      sleep "$limit"
      if kill -0 "$captured_pid" 2>/dev/null; then
        : >"${output}.timeout"
        terminate_tree "$captured_pid"
      fi
    ) &
    timer_pid=$!
    [ -z "$state_dir" ] || : >"$state_dir/children/$timer_pid"
  fi
  wait "$captured_pid" 2>/dev/null; command_result=$?
  if [ -n "$timer_pid" ]; then
    terminate_tree "$timer_pid"
    wait "$timer_pid" 2>/dev/null || true
  fi
  [ ! -f "${output}.timeout" ] || command_result=124
  finished=$(date +%s)
  printf 'end_epoch=%s\nexit_code=%s\nelapsed_seconds=%s\n' "$finished" "$command_result" "$((finished-started))" >>"${output}.meta"
  if [ -n "$state_dir" ]; then
    rm -f "$state_dir/children/$captured_pid"
    [ -z "$timer_pid" ] || rm -f "$state_dir/children/$timer_pid"
  fi
  return "$command_result"
}
start_worker() {
  (
    trap - EXIT INT TERM HUP
    "$@"
  ) &
  worker_pids+=("$!")
}
stop_workers() {
  local pid
  [ -z "$scenario_dir" ] || : >"$scenario_dir/.stop"
  for pid in ${worker_pids[@]+"${worker_pids[@]}"}; do terminate_tree "$pid"; done
  for pid in ${worker_pids[@]+"${worker_pids[@]}"}; do wait "$pid" 2>/dev/null || true; done
  worker_pids=()
}
mark_event() {
  printf '%s\t%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$(date +%s)" "$*" >>"$scenario_dir/user-events.tsv"
}
find_adb() {
  local candidate
  for candidate in "$script_dir/platform-tools/adb" "$script_dir/adb" "$HOME/Library/Android/sdk/platform-tools/adb" "$(command -v adb 2>/dev/null || true)"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then adb_path="$candidate"; return 0; fi
  done
  return 1
}
adb_capture() {
  local output="$1" limit="$2"; shift 2
  run_capture "$output" "$limit" "$adb_path" -s "$adb_serial" "$@"
}
adb_online() {
  [ -n "$adb_serial" ] || return 1
  adb_capture "$scenario_dir/android/connection-check.txt" 4 get-state || return 1
  grep -qx 'device' "$scenario_dir/android/connection-check.txt"
}
select_adb_device() {
  local listing="$scenario_dir/android/adb-devices.txt" count
  run_capture "$listing" 8 "$adb_path" devices -l || return 1
  { printf 'mac_epoch=%s\n' "$(date +%s)"; cat "$listing"; } >>"$scenario_dir/android/adb-authorization-timeline.txt"
  count=$(awk '$2 ~ /^(device|unauthorized|offline)$/ && / usb:/ {n++} END {print n+0}' "$listing")
  if [ "$count" = 1 ] && [ "$(awk '$2 == "device" && / usb:/ {n++} END {print n+0}' "$listing")" = 1 ]; then
    adb_serial=$(awk '$2 == "device" && / usb:/ {print $1}' "$listing")
    return 0
  fi
  [ "${1:-}" != --quiet ] || return 1
  if [ "$count" -gt 1 ]; then
    info "检测到多台通过 USB 调试连接的设备. 请只保留本次测试的手机."
  elif grep -q 'unauthorized' "$listing"; then
    info "手机尚未允许调试. 请解锁手机, 在手机弹窗中允许这台 Mac."
  elif grep -q 'offline' "$listing"; then
    info "手机调试连接暂未就绪. 请重新插好数据线, 并保持手机解锁."
  else
    info "未检测到已授权的 USB 调试连接. Wi-Fi 调试连接不能用于本次 USB 测试."
    info "请检查数据线是否支持传输数据, 并在手机开发者选项中开启 USB 调试."
  fi
  return 1
}
# Match the executable, not a command line containing our own search text.
# Include every installation path, but only processes owned by this user.
handshaker_processes() {
  ps -axo uid=,pid=,comm= | awk -v owner="$EUID" -v wanted="${1:-all}" '
    $1==owner {
      pid=$2; sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/, "")
      kind=""
      if ($0 ~ /\/Contents\/MacOS\/HandShaker$/) kind="app"
      if ($0 ~ /\/Contents\/MacOS\/HandShakerAgent$/) kind="agent"
      if (kind!="" && (wanted=="all" || wanted==kind)) printf "%s\t%s\t%s\n", pid, kind, $0
    }'
}
find_pid() {
  handshaker_processes app | awk -F '\t' -v path="$app_executable" '$3==path {print $1; exit}'
}
mac_diagnostic_event() {
  awk -v run="$run_id" -v pid="$1" -v pattern="$2" '
    index($0, " run=" run " ") && index($0, " pid=" pid " ") && $0 ~ pattern {found=1; exit}
    END {exit !found}
  ' "$scenario_dir/mac/usb-diagnostic.log" 2>/dev/null
}
capture_mac_processes() {
  local prefix="$1" pid kind executable
  run_capture "$prefix/processes.tsv" 8 handshaker_processes || true
  while IFS=$'\t' read -r pid kind executable; do
    [ -n "$pid" ] || continue
    run_capture "$prefix/process-$pid.txt" 8 ps -p "$pid" -o uid,pid,ppid,lstart,stat,command || true
    if [ -f "$executable" ]; then
      printf 'executable_exists=yes\n' >>"$prefix/process-$pid.txt"
    else
      printf 'executable_exists=no\n' >>"$prefix/process-$pid.txt"
    fi
  done <"$prefix/processes.tsv"
}
handshaker_jobs() {
  local kind="$1" processes="$2"
  launchctl list | awk -v wanted="$kind" '
    FILENAME==ARGV[1] {owned[$1]=1; next}
    {
      label=$3
      known=(wanted=="agent" && label ~ /^(application\.)?com\.smartisan\.SmartFinder\.HandShakerAgent(\.|$)/) ||
            (wanted=="app" && label ~ /^(application\.)?com\.smartisan\.smartfindercommon(\.|$)/)
      if (known || ($1 in owned)) print label
    }' "$processes" -
}
signal_handshaker_process() {
  local pid="$1" kind="$2" executable="$3" current
  current=$(handshaker_processes "$kind" | awk -F '\t' -v pid="$pid" '$1==pid {print $3}')
  [ "$current" = "$executable" ] || return 0
  /bin/kill -TERM "$pid"
}
stop_mac_kind() {
  local kind="$1" prefix="$2" job target pid found_kind executable count
  run_capture "$prefix/processes-before.tsv" 8 handshaker_processes "$kind" || return 1
  run_capture "$prefix/jobs-before.txt" 8 handshaker_jobs "$kind" "$prefix/processes-before.tsv" || return 1
  while IFS= read -r job; do
    [ -n "$job" ] || continue
    target="gui/$EUID/$job"
    # Save launch provenance without exporting the job's environment variables.
    # shellcheck disable=SC2016
    run_capture "$prefix/job-$job.txt" 8 /bin/bash -o pipefail -c '
      launchctl print "$1" | awk "/^[[:space:]]*(path|type|managed_by|state|bundle id|program|domain|runs|pid|last exit code|properties) =/ {print}"
    ' _ "$target" || true
    # Remove only the current login session job. Do not disable login items or
    # edit preferences. Restarting an old helper here would restart the loop.
    run_capture "$prefix/bootout-$job.txt" 8 launchctl bootout "$target" || true
  done <"$prefix/jobs-before.txt"
  run_capture "$prefix/processes-after-bootout.tsv" 8 handshaker_processes "$kind" || return 1
  while IFS=$'\t' read -r pid found_kind executable; do
    [ -n "$pid" ] || continue
    run_capture "$prefix/terminate-$pid.txt" 5 signal_handshaker_process "$pid" "$found_kind" "$executable" || true
  done <"$prefix/processes-after-bootout.tsv"
  for count in 1 2 3 4 5; do
    [ -n "$(handshaker_processes "$kind")" ] || break
    sleep 1
  done
  run_capture "$prefix/processes-after.tsv" 8 handshaker_processes "$kind" || return 1
  run_capture "$prefix/jobs-after.txt" 8 handshaker_jobs "$kind" "$prefix/processes-after.tsv" || return 1
  [ ! -s "$prefix/processes-after.tsv" ] && [ ! -s "$prefix/jobs-after.txt" ]
}
close_handshaker() {
  local reason="${1:-prepare}" attempt prefix
  mac_close_sequence=$((mac_close_sequence+1))
  prefix="$scenario_dir/mac/shutdown-$mac_close_sequence-$reason"
  capture_mac_processes "$prefix/before"
  mark_event "mac-stop-begin reason=$reason"
  # Bound retries. If another launcher wins, retain evidence and stop the run.
  for attempt in 1 2; do
    stop_mac_kind agent "$prefix/attempt-$attempt/agent" || continue
    stop_mac_kind app "$prefix/attempt-$attempt/app" || continue
    if [ -z "$(handshaker_processes)" ]; then
      mark_event "mac-stop-complete reason=$reason"
      return 0
    fi
  done
  capture_mac_processes "$prefix/remaining"
  capture_sample quit-timeout
  info "HandShaker 或旧后台助手仍在运行. 已保存启动来源, 本轮不会继续连接测试."
  return 1
}
capture_common() {
  printf 'bundle_id=%s\nscript_revision=%s\nscript_directory=%s\nbash_version=%s\n' "$(manifest_value BUNDLE_ID)" "$script_revision" "$script_dir" "$BASH_VERSION" >"$out_dir/common/script-info.txt"
  run_capture "$out_dir/common/system.txt" 8 sw_vers || true
  run_capture "$out_dir/common/hardware.txt" 20 system_profiler SPHardwareDataType || true
  run_capture "$out_dir/common/disk.txt" 8 df -h "$out_dir" || true
  run_capture "$out_dir/common/app-info.txt" 8 plutil -p "$app_path/Contents/Info.plist" || true
  run_capture "$out_dir/common/app-signature.txt" 10 codesign -dv --verbose=4 "$app_path" || true
  run_capture "$out_dir/common/app-fingerprints.txt" 15 shasum -a 256 \
    "$app_executable" "$app_path/Contents/Frameworks/SmartFinderCore.framework/Versions/A/CorePatch" \
    "$app_path/Contents/Frameworks/SmartFinderCore.framework/Versions/A/SmartFinderCore" || true
  [ ! -f "$script_dir/diagnostic-manifest.txt" ] || cp "$script_dir/diagnostic-manifest.txt" "$out_dir/common/diagnostic-manifest.txt"
}
usb_prop() {
  awk -v key="$2" 'index($0,"[" key "]: [")==1 {v=substr($0,length(key)+6); sub(/]\r?$/,"",v); print v; exit}' "$1" 2>/dev/null
}
usb_command_value() {
  local file="$1" result
  if ! grep -qx 'exit_code=0' "$file.meta" 2>/dev/null; then printf 'unknown'; return; fi
  if grep -Eiq 'No shell command implementation|Unknown command|not found|not supported|Permission Denial|Exception|Error' "$file"; then
    printf 'unsupported'; return
  fi
  result=$(tr -d '\r\n' <"$file")
  case "$result" in ''|*[!a-zA-Z0-9_,\ -]*) printf 'unknown' ;; *) printf '%s' "$result" ;; esac
}
write_usb_config() {
  local label="$1" prefix="$scenario_dir/android" key value
  {
    printf 'label=%s\nmac_epoch=%s\n' "$label" "$(date +%s)"
    for key in persist.sys.usb.config persist.vendor.usb.config sys.usb.config sys.usb.state; do
      value=$(usb_prop "$prefix/getprop-$label.txt" "$key")
      printf '%s=%s\n' "$key" "${value:-unknown}"
    done
    printf 'cmd.current_functions=%s\n' "$(usb_command_value "$prefix/usb-functions-$label.txt")"
    printf 'cmd.screen_unlocked_functions=%s\n' "$(usb_command_value "$prefix/usb-unlocked-functions-$label.txt")"
    printf 'phone_ui_label=not-inferred-from-functions\n'
  } >"$prefix/usb-config-$label.txt"
}
capture_android_state() {
  local label="$1" prefix="$scenario_dir/android"
  mark_event "android-state-begin label=$label"
  printf 'mac_before_epoch=%s\n' "$(date +%s)" >"$prefix/clock-${label}.txt"
  adb_capture "$prefix/time-${label}.txt" 8 shell 'date "+%s %Y-%m-%dT%H:%M:%S%z"' || true
  printf 'mac_after_epoch=%s\n' "$(date +%s)" >>"$prefix/clock-${label}.txt"
  adb_capture "$prefix/uptime-${label}.txt" 8 shell cat /proc/uptime || true
  adb_capture "$prefix/getprop-${label}.txt" 10 shell getprop || true
  adb_capture "$prefix/dumpsys-usb-${label}.txt" 15 shell dumpsys usb || true
  adb_capture "$prefix/usb-functions-${label}.txt" 8 shell cmd usb get-functions || true
  adb_capture "$prefix/usb-unlocked-functions-${label}.txt" 8 shell cmd usb get-screen-unlocked-functions || true
  adb_capture "$prefix/debug-settings-${label}.txt" 8 shell \
    'printf "adb_enabled="; settings get global adb_enabled; printf "development_settings_enabled="; settings get global development_settings_enabled' || true
  adb_capture "$prefix/users-${label}.txt" 8 shell pm list users || true
  adb_capture "$prefix/appops-${label}.txt" 10 shell cmd appops get --user "$android_user" "$android_package" || true
  adb_capture "$prefix/package-${label}.txt" 15 shell dumpsys package "$android_package" || true
  adb_capture "$prefix/services-${label}.txt" 15 shell dumpsys activity services "$android_package" || true
  adb_capture "$prefix/processes-${label}.txt" 10 shell ps -A || true
  adb_capture "$prefix/meminfo-${label}.txt" 15 shell dumpsys meminfo "$android_package" || true
  adb_capture "$prefix/exit-info-${label}.txt" 15 shell dumpsys activity exit-info "$android_package" || true
  adb_capture "$prefix/activities-${label}.txt" 15 shell dumpsys activity activities "$android_package" || true
  adb_capture "$prefix/battery-policy-${label}.txt" 10 shell dumpsys deviceidle whitelist || true
  write_usb_config "$label"
  mark_event "android-state-end label=$label"
}
record_usb_label() {
  local label="$1"
  choice "$scenario_dir/usb-label-$label.txt" '手机当前显示的 USB 用途是哪一项? 只查看, 不要修改选项.' '0,1,2,3,4,5' \
    '1. 仅充电 / 不传输数据' '2. 文件传输 / Android Auto' '3. 传输照片 / PTP' \
    '4. USB 网络共享' '5. 其他用途' '0. 看不到 / 不确定, 直接继续' || return 130
  mark_event "phone-ui-usb-label phase=$label option=$(cat "$scenario_dir/usb-label-$label.txt") source=user"
}
show_initial_usb_config() {
  local config state
  config=$(usb_prop "$scenario_dir/android/getprop-before-install.txt" sys.usb.config)
  state=$(usb_prop "$scenario_dir/android/getprop-before-install.txt" sys.usb.state)
  info "已确认 USB 调试授权. USB 请求配置: ${config:-未知}; 实际配置: ${state:-未知}."
  case ",$state," in
    *,mtp,*) info "检测到 MTP(系统文件传输). 已记录, 本轮保留这个设置." ;;
    *,accessory,*) info "检测到 USB 配件模式. 已记录当前状态, 后面会按提示做一次物理拔插." ;;
    *,adb,*|*,none,*) info "当前未检测到 MTP. 仅充电也可能正常使用 HandShaker, 本轮保留原设置." ;;
    *) info "已保存可读取的 USB 状态. 读取不到的项目会标为未知, 不会自动判错." ;;
  esac
}

pull_android_logs() {
  local label="$1" prefix="$scenario_dir/android" suffix
  for suffix in '' '.previous'; do
    adb_capture "$prefix/pull-${label}${suffix}.txt" 15 pull \
      "$android_external_dir/handshaker-usb-diagnostic.log${suffix}" "$prefix/handshaker-${label}.log${suffix}" || true
    adb_capture "$prefix/internal-${label}.log${suffix}" 10 exec-out run-as "$android_package" --user "$android_user" \
      cat "files/handshaker-usb-diagnostic.log${suffix}" || true
  done
  adb_capture "$prefix/usb-status-${label}.xml" 10 exec-out run-as "$android_package" --user "$android_user" \
    cat shared_prefs/usb_status.xml || true
}
capture_android_exit_evidence() {
  local label="$1" prefix="$scenario_dir/android"
  mark_event "android-exit-snapshot label=$label"
  adb_capture "$prefix/logcat-${label}.txt" 15 logcat -d -b all -t 8000 -v epoch \
    'HandShakerUSB:V' 'HandShakerDiag:V' 'AndroidRuntime:V' 'ActivityManager:I' 'ActivityTaskManager:I' \
    'am_crash:I' 'am_anr:I' 'am_proc_died:I' 'am_kill:I' 'am_finish_activity:I' 'wm_finish_activity:I' \
    'PackageManager:I' 'UsbDeviceManager:V' 'UsbHostManager:V' 'UsbService:V' '*:W' || true
  adb_capture "$prefix/exit-info-${label}.txt" 12 shell dumpsys activity exit-info "$android_package" || true
  adb_capture "$prefix/activities-${label}.txt" 12 shell dumpsys activity activities "$android_package" || true
  adb_capture "$prefix/processes-${label}.txt" 8 shell ps -A || true
}
stop_android_app() {
  local reason="$1"
  # Record intentional stops separately from a crash or an observed disconnect.
  mark_event "android-force-stop reason=$reason user=$android_user"
  adb_capture "$scenario_dir/android/app-force-stop-${reason}.txt" 8 shell am force-stop --user "$android_user" "$android_package"
}
capture_installed_android_signing() {
  local prefix="$scenario_dir/android/signing-before-install" installed_apk entry name
  local local_apk="$state_dir/installed-base.apk"
  adb_capture "$prefix/package-path.txt" 8 shell pm path --user "$android_user" "$android_package" || return 0
  installed_apk=$(tr -d '\r' <"$prefix/package-path.txt" | awk '
    /^package:/ {
      sub(/^package:/, ""); if (first=="") first=$0
      if ($0 ~ /\/base\.apk$/) {print; found=1; exit}
    } END {if (!found) print first}')
  case "$installed_apk" in /*.apk) ;; *) return 0 ;; esac
  if ! adb_capture "$prefix/pull-apk.txt" 30 pull "$installed_apk" "$local_apk"; then
    rm -f "$local_apk"
    return 0
  fi
  run_capture "$prefix/apk-sha256.txt" 10 shasum -a 256 "$local_apk" || true
  run_capture "$prefix/apk-entries.txt" 10 unzip -Z1 "$local_apk" || true
  # Keep public v1 signing certificates, not the installed application's APK.
  # A missing v1 block does not mean the APK lacks a v2/v3 signature.
  while IFS= read -r entry; do
    name=${entry##*/}
    run_capture "$prefix/$name.pkcs7" 8 unzip -p "$local_apk" "$entry" || continue
    run_capture "$prefix/$name.pem" 8 /usr/bin/openssl pkcs7 -inform DER -in "$prefix/$name.pkcs7" -print_certs || continue
    run_capture "$prefix/$name-first-cert.txt" 8 /usr/bin/openssl x509 -in "$prefix/$name.pem" \
      -noout -subject -issuer -serial -fingerprint -sha256 || true
  done < <(grep -E '^META-INF/[A-Za-z0-9_.-]+\.(RSA|DSA|EC)$' "$prefix/apk-entries.txt")
  rm -f "$local_apk"
  printf 'scope=v1-public-certificates\nexpected_signer_sha256=%s\n' "$(manifest_value ANDROID_SIGNER_CERT_SHA256)" >"$prefix/scope.txt"
}
capture_usb() {
  local label="$1"
  run_capture "$scenario_dir/mac/ioreg-usb-${label}.txt" 8 ioreg -p IOUSB -l -w0 || true
  run_capture "$scenario_dir/mac/ioreg-interfaces-${label}.txt" 8 ioreg -r -c IOUSBHostInterface -l -w0 || true
  run_capture "$scenario_dir/mac/usb-${label}.txt" 25 system_profiler SPUSBDataType || true
  if [ -f "$script_dir/usb_link.awk" ]; then
    awk -v target_serial="$adb_serial" -v target_location="$usb_location" -f "$script_dir/usb_link.awk" "$scenario_dir/mac/ioreg-usb-${label}.txt" >"$scenario_dir/mac/link-${label}.txt"
  fi
}
capture_sample() {
  local label="$1" pid
  pid=$(find_pid)
  [ -n "$pid" ] || return 0
  run_capture "$scenario_dir/mac/process-${label}.txt" 8 ps -p "$pid" -o pid,ppid,stat,%cpu,%mem,etime,command || true
  run_capture "$scenario_dir/mac/sample-${label}.stderr.txt" 10 /usr/bin/sample "$pid" 2 10 -file "$scenario_dir/mac/sample-${label}.txt" || true
}
capture_mac_files() {
  local file label stage="${1:-after}" directory="$HOME/Library/Application Support/HandShaker/logs"
  local prefix="$scenario_dir/mac/$stage"
  mkdir -p "$prefix/app-logs" "$prefix/crash-reports"
  for file in "$directory/maintained.log" "$directory/maintained.log.previous" "$directory/usb-diagnostic.log" \
    "$directory/usb-diagnostic.log.previous" "$directory/$(date +%Y%m%d).log"; do
    [ -f "$file" ] || continue
    label=${file##*/}
    run_capture "$prefix/app-logs/$label" 8 tail -c 8388608 "$file" || true
  done
  printf 'stage=%s\npreexisting_reports_are_history_not_incident_attribution=yes\n' "$stage" >"$prefix/scope.txt"
  while IFS= read -r -d '' file; do
    if [ "$stage" != preexisting ] && [ ! "$file" -nt "$out_dir/run-id.txt" ]; then continue; fi
    label=${file##*/}
    run_capture "$prefix/crash-reports/$label" 8 cat "$file" || true
  done < <(find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -type f \
    \( -name 'HandShaker*.ips' -o -name 'HandShaker*.crash' \) -mtime -1 -print0 2>/dev/null)
}
usb_monitor() {
  local index=0 label
  while [ ! -f "$scenario_dir/.stop" ]; do
    [ ! -f "$state_dir/adb-serial.txt" ] || adb_serial=$(cat "$state_dir/adb-serial.txt")
    [ ! -f "$state_dir/usb-location.txt" ] || usb_location=$(cat "$state_dir/usb-location.txt")
    label=$(printf '%05d' "$index")
    run_capture "$scenario_dir/mac/timeline/usb-${label}.txt" 6 ioreg -p IOUSB -l -w0 || true
    {
      printf 'epoch=%s sample=%s\n' "$(date +%s)" "$label"
      awk -v target_serial="$adb_serial" -v target_location="$usb_location" -f "$script_dir/usb_link.awk" "$scenario_dir/mac/timeline/usb-${label}.txt"
    } >>"$scenario_dir/mac/usb-timeline.txt"
    index=$((index+1)); sleep 2
  done
}
android_monitor() {
  local index=0 label state previous=""
  while [ ! -f "$scenario_dir/.stop" ]; do
    label=$(printf '%05d' "$index")
    # Expand p on the Android shell, not on the Mac.
    # shellcheck disable=SC2016
    if adb_capture "$scenario_dir/android/timeline/state-${label}.txt" 6 shell \
      'printf "phone_epoch="; date +%s; printf "uptime="; cat /proc/uptime; for p in persist.sys.usb.config sys.usb.config sys.usb.state; do printf "%s=" "$p"; getprop "$p"; done; printf "app_pids="; pidof com.smartisanos.smartfolder.aoa; echo'; then
      state=$(grep -E '^(persist.sys.usb.config|sys.usb.config|sys.usb.state)=' "$scenario_dir/android/timeline/state-${label}.txt" | tr -d '\r')
      if [ "$state" != "$previous" ]; then
        {
          printf 'mac_epoch=%s sample=%s source=properties cause=unknown\n' "$(date +%s)" "$label"
          printf '%s\n' "$state"
        } >>"$scenario_dir/android/usb-config-changes.txt"
        adb_capture "$scenario_dir/android/timeline/usb-change-${label}.txt" 12 shell dumpsys usb || true
        previous="$state"
      fi
    else
      if [ "$previous" != adb-unavailable ]; then
        printf 'mac_epoch=%s sample=%s adb=unavailable usb_functions=unknown\n' "$(date +%s)" "$label" >>"$scenario_dir/android/usb-config-changes.txt"
        previous=adb-unavailable
      fi
    fi
    index=$((index+1)); sleep 3
  done
}

android_log_monitor() {
  local index=0 label
  while [ ! -f "$scenario_dir/.stop" ]; do
    label=$(printf '%03d' "$index")
    # Retain USB, SystemUI, lifecycle and error events live across re-enumeration.
    adb_capture "$scenario_dir/android/live/logcat-${label}.txt" 600 logcat -b all -v epoch -T 2000 \
      'HandShakerUSB:V' 'HandShakerDiag:V' 'UsbDeviceManager:V' 'UsbHostManager:V' 'UsbPortManager:V' 'UsbService:V' \
      'SystemUi--Common:I' 'OplusViewDragTouchViewHelper:D' 'ActivityManager:I' 'ActivityTaskManager:I' 'AndroidRuntime:V' \
      'am_crash:I' 'am_anr:I' 'am_proc_died:I' 'am_kill:I' 'am_finish_activity:I' 'wm_finish_activity:I' '*:W' || true
    index=$((index+1)); sleep 1
  done
}
sample_monitor() {
  local index=0
  while [ ! -f "$scenario_dir/.stop" ]; do
    capture_mac_processes "$scenario_dir/mac/runtime-$(printf '%03d' "$index")"
    capture_sample "$(printf '%03d' "$index")"
    index=$((index+1)); sleep 15
  done
}
mac_log_monitor() {
  local index=0 label
  while [ ! -f "$scenario_dir/.stop" ]; do
    label=$(printf '%03d' "$index")
    run_capture "$scenario_dir/mac/system-log-live-$label.txt" 600 /usr/bin/log stream --style syslog --level debug \
      --predicate 'process == "HandShaker" OR process == "HandShakerAgent" OR ((process == "runningboardd" OR process == "launchd") AND eventMessage CONTAINS[c] "com.smartisan") OR subsystem BEGINSWITH "com.apple.usb" OR (process == "kernel" AND eventMessage CONTAINS[c] "USB")' || true
    index=$((index+1)); sleep 1
  done
}
check_android_permissions() {
  local attempt=0 check record prefix="$scenario_dir/android"
  info "请在手机上允许 HandShaker 的文件访问和定位权限. 有精确位置选项时请开启."
  info "Android 11 及以上需要所有文件访问权限; 较旧系统需要存储读写权限."
  info "USB 配件授权会在正式接线时单独记录."
  while :; do
    attempt=$((attempt+1)); check="permissions-$attempt-$(date +%s)"
    adb_capture "$prefix/permission-launch-${attempt}.txt" 20 shell am start --user "$android_user" -W \
      -n "$android_package/.MainActivity" --es handshaker_diagnostic_run "$run_id" --es handshaker_diagnostic_check "$check" || true
    adb_capture "$prefix/preflight-log.txt" 10 exec-out cat "$android_external_dir/handshaker-usb-diagnostic.log" || true
    adb_capture "$prefix/permission-logcat-${attempt}.txt" 10 logcat -d -b all -v epoch -t 2000 || true
    record=$(cat "$prefix/preflight-log.txt" "$prefix/permission-logcat-${attempt}.txt" | \
      grep -F "run=$run_id event=PERMISSIONS check=$check " | tail -1 || true)
    printf '%s\n' "$record" >"$prefix/permissions-${attempt}.txt"
    if [ -z "$record" ]; then
      info "暂未收到本次权限检查结果. 请确认手机已解锁且 HandShaker 没有退出."
      capture_android_exit_evidence "permission-$attempt"
    else
      case "$record" in
        *' requiredReady=true '*)
          cp "$prefix/permissions-${attempt}.txt" "$prefix/permissions-ready.txt"
          info "文件访问和定位权限已通过检查."
          case "$record" in *'batteryExempt=false'*) info "已记录省电限制. 本轮让 HandShaker 保持前台, 手机保持解锁." ;; esac
          return 0 ;;
      esac
      info "尚未就绪的权限:"
      case "$record" in *' storageReady=false '*) info "文件访问: 允许存储访问, 或开启所有文件访问权限." ;; esac
      case "$record" in *' fineLocation=false '*|*' coarseLocation=false '*) info "定位: 允许使用期间访问位置, 并开启精确位置(如有)." ;; esac
    fi
    prompt_enter "在手机上完成授权, 返回 HandShaker 页面" || return 130
  done
}
wait_for_usb_state() {
  local wanted="$1" present key started
  local snapshot="$scenario_dir/mac/connection-gate.txt"
  printf 'waiting-usb-%s\n' "$wanted" >"$scenario_dir/round-status.txt"
  mark_event "usb-gate-wait state=$wanted"
  started=$(date +%s)
  while :; do
    if run_capture "$snapshot" 6 ioreg -p IOUSB -l -w0; then
      awk -v target_serial="$adb_serial" -v target_location="$usb_location" -f "$script_dir/usb_link.awk" "$snapshot" >"${snapshot}.link"
      present=1
      grep -q '^PHONE_NONE=1$' "${snapshot}.link" && present=0
      if ! grep -q '^PHONE_AMBIGUOUS=1$' "${snapshot}.link" && \
        { { [ "$wanted" = present ] && [ "$present" = 1 ]; } || { [ "$wanted" = absent ] && [ "$present" = 0 ]; }; }; then
        mark_event "usb-gate-$wanted"; return 0
      fi
    fi
    if [ "$wanted" = present ] && awk -v first="$started" -v run="$run_id" '
      index($0," run=" run " ") && /event=(HANDSHAKE_BEGIN|DEVICE_ADDED)/ {
        for (i=1;i<=NF;i++) if ($i ~ /^wallMs=/ && substr($i,8)+0>=first*1000) found=1
      } END {exit !found}' "$scenario_dir/mac/usb-diagnostic.log" 2>/dev/null; then
      mark_event usb-gate-connection-event; return 0
    fi
    key=""
    # macOS Bash 3.2 returns 1 on read timeout as well as EOF. Keep polling
    # an interactive terminal until USB state changes or Q is entered.
    if IFS= read -r -t 2 -n 1 key; then
      case "$key" in
        q|Q) mark_event "usb-gate-cancelled state=$wanted input=q"; return 130 ;;
      esac
    elif [ ! -t 0 ]; then
      mark_event "usb-gate-input-unavailable state=$wanted"
      info "无法继续读取终端输入, 将保存已收集的日志."
      return 130
    fi
  done
}
inventory_android_installs() {
  local id name list="$scenario_dir/android/installed-users.tsv"
  adb_capture "$scenario_dir/android/install-users.txt" 10 shell pm list users || return 1
  grep -q 'UserInfo{' "$scenario_dir/android/install-users.txt" || return 1
  : >"$list"
  while IFS=$'\t' read -r id name; do
    case "$id" in ''|*[!0-9]*) return 1 ;; esac
    adb_capture "$scenario_dir/android/installed-user-$id.txt" 10 shell pm list packages --user "$id" "$android_package" || return 1
    if grep -Eiq 'Error|Exception|Permission Denial' "$scenario_dir/android/installed-user-$id.txt"; then return 1; fi
    if tr -d '\r' <"$scenario_dir/android/installed-user-$id.txt" | grep -qx "package:$android_package"; then
      printf '%s\t%s\n' "$id" "$name" >>"$list"
    fi
  done < <(awk '/UserInfo\{/ {sub(/.*UserInfo\{/,""); split($0,a,":"); printf "%s\t%s\n",a[1],a[2]}' "$scenario_dir/android/install-users.txt")
}
stop_installed_android_apps() {
  local reason="$1" id name
  while IFS=$'\t' read -r id name; do
    [ -n "$id" ] || continue
    mark_event "android-force-stop reason=$reason user=$id"
    adb_capture "$scenario_dir/android/app-force-stop-${reason}-user-$id.txt" 8 shell am force-stop --user "$id" "$android_package" || return 1
  done <"$scenario_dir/android/installed-users.tsv"
}
prepare_android() {
  find_adb || { info "测试包中缺少 adb. 请完整解压测试包."; return 1; }
  [ -f "$diagnostic_apk" ] || { info "未找到包内 Android 安装包. 请完整解压测试包."; return 1; }
  run_capture "$scenario_dir/android/adb-version.txt" 8 "$adb_path" version || return 1
  run_capture "$scenario_dir/android/adb-start-server.txt" 10 "$adb_path" start-server || return 1
  if select_adb_device --quiet; then
    info "已检测到一台已授权的 USB 手机, 自动继续."
  else
    info "现在请连接唯一一台测试手机, 使用原来出问题的数据线和连接方式."
    info "在开发者选项中开启 USB 调试, 解锁手机并允许这台 Mac. USB 用途保留原设置."
    while :; do
      prompt_enter "完成接线和 USB 调试授权" || return 130
      select_adb_device && break
    done
  fi
  printf '%s\n' "$adb_serial" >"$scenario_dir/android/adb-serial.txt"
  cp "$scenario_dir/android/adb-serial.txt" "$state_dir/adb-serial.txt"
  adb_capture "$scenario_dir/android/current-user.txt" 8 shell am get-current-user || return 1
  android_user=$(tr -d '\r\n ' <"$scenario_dir/android/current-user.txt")
  case "$android_user" in ''|*[!0-9]*) info "无法确认 Android 当前用户, 已保留现场."; return 1 ;; esac
  android_external_dir="/storage/emulated/$android_user/Android/data/$android_package/files"
  start_worker android_log_monitor
  start_worker android_monitor
  info "正在保存旧应用的退出记录和初始状态, 随后停止两端 HandShaker..."
  adb_capture "$scenario_dir/android/getprop-initial.txt" 10 shell getprop || true
  adb_capture "$scenario_dir/android/dumpsys-usb-initial.txt" 12 shell dumpsys usb || true
  adb_capture "$scenario_dir/android/usb-functions-initial.txt" 8 shell cmd usb get-functions || true
  adb_capture "$scenario_dir/android/usb-unlocked-functions-initial.txt" 8 shell cmd usb get-screen-unlocked-functions || true
  write_usb_config initial
  capture_android_exit_evidence before-stop
  pull_android_logs before-install
  inventory_android_installs || { info "无法完整读取手机用户和应用分身列表, 已保留日志."; return 1; }
  stop_installed_android_apps before-install || return 1
  close_handshaker after-connect || return 1
  capture_common
  capture_android_state before-install
  capture_installed_android_signing
  capture_usb connected
  usb_location=$(awk -F= '$1=="PHONE_LOCATION" {print $2}' "$scenario_dir/mac/link-connected.txt")
  if [ -z "$usb_location" ]; then
    info "无法在 Mac USB 列表中定位这台手机, 已保留拓扑和调试记录."; return 1
  fi
  printf '%s\n' "$usb_location" >"$state_dir/usb-location.txt"
  show_initial_usb_config
  record_usb_label initial || return 130
  info "两端初始信息已保存. 接下来进行 Android 卸载和安装."
}
install_android_clean() {
  local id name attempt=0 expected decision
  if [ -s "$scenario_dir/android/installed-users.tsv" ]; then
    info "检测到以下 HandShaker 副本:"
    while IFS=$'\t' read -r id name; do info "Android 用户 $id: $name"; done <"$scenario_dir/android/installed-users.tsv"
    info "本轮需要卸载这些 HandShaker 副本, 再安装包内诊断版, 以重新检查首次启动和授权."
    info "卸载会清除这些副本的应用数据和授权. 请先保存需要保留的应用内数据."
    choice "$scenario_dir/android/uninstall-consent.txt" '确认卸载上面列出的 HandShaker 副本并继续?' '1,2' \
      '1. 确认卸载并安装诊断版' '2. 保留现状, 保存日志并结束' || return 130
    decision=$(cat "$scenario_dir/android/uninstall-consent.txt")
    if [ "$decision" != 1 ]; then printf 'user-declined-uninstall\n' >"$scenario_dir/round-status.txt"; return 130; fi
    while IFS=$'\t' read -r id name; do
      [ "$id" != "$android_user" ] || continue
      adb_capture "$scenario_dir/android/profile-$id-log-before-uninstall.txt" 15 exec-out \
        cat "/storage/emulated/$id/Android/data/$android_package/files/handshaker-usb-diagnostic.log" || true
    done <"$scenario_dir/android/installed-users.tsv"
    mark_event android-uninstall-begin
    info "正在卸载旧 HandShaker..."
    if ! adb_capture "$scenario_dir/android/apk-uninstall.txt" 60 uninstall "$android_package" || \
      ! grep -q '^Success' "$scenario_dir/android/apk-uninstall.txt"; then
      printf 'android-uninstall-failed\n' >"$scenario_dir/round-status.txt"
      info "旧应用卸载未完成. 已保留系统返回原因, 本轮将保存日志并结束."; return 1
    fi
    mark_event android-uninstall-complete
    info "旧应用已卸载."
  else
    info "手机没有已安装的 HandShaker, 将直接安装诊断版."
  fi
  while :; do
    attempt=$((attempt+1))
    info "正在安装 Android 诊断版. 手机若询问是否允许本次安装, 请选择允许."
    mark_event "android-install-begin attempt=$attempt"
    if adb_capture "$scenario_dir/android/apk-install-${attempt}.txt" 0 install --user "$android_user" "$diagnostic_apk" && \
      grep -q '^Success' "$scenario_dir/android/apk-install-${attempt}.txt"; then break; fi
    printf 'android-install-failed\n' >"$scenario_dir/round-status.txt"
    if grep -q 'UPDATE_INCOMPATIBLE' "$scenario_dir/android/apk-install-${attempt}.txt"; then
      info "系统仍报告签名冲突. 已保存各用户安装情况, 请回传日志, 本轮尚未进入连接测试."
      return 1
    fi
    info "安装未完成, 原因如下:"
    tail -n 5 "$scenario_dir/android/apk-install-${attempt}.txt"
    prompt_enter "按手机提示允许 USB 安装, 再重试安装" || return 130
  done
  mark_event android-install-complete
  info "Android 诊断版安装成功. 接下来会打开手机 App 并检查权限."
  adb_capture "$scenario_dir/android/package-installed.txt" 15 shell dumpsys package "$android_package" || return 1
  expected=$(manifest_value ANDROID_VERSION_CODE)
  if [ -z "$expected" ] || ! grep -q "versionCode=$expected " "$scenario_dir/android/package-installed.txt"; then
    info "手机实际安装版本与测试包不一致, 已保留版本信息."; return 1
  fi
  printf 'android-installed\n' >"$scenario_dir/round-status.txt"
}
check_mac_installation() {
  local expected actual
  expected=$(manifest_value MAC_BUILD)
  [ -n "$expected" ] || { info "缺少测试包版本清单, 请完整解压测试包."; return 1; }
  while :; do
    actual=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_path/Contents/Info.plist" 2>/dev/null || true)
    if [ -f "$app_executable" ] && [ "$actual" = "$expected" ]; then break; fi
    info "Mac 尚未安装本测试包对应的版本."
    prompt_enter "打开 1-安装Mac端.dmg, 将 HandShaker 拖入 Applications 并替换旧版, 暂时不要手动启动" || return 130
  done
  run_capture "$out_dir/common/installed-app-verify.txt" 15 codesign --verify --deep --strict "$app_path" || {
    info "Mac 应用签名校验未通过. 请重新安装包内版本."; return 1;
  }
  info "Mac 诊断版已安装, 版本检查通过."
}

prepare_mac() {
  local attempt=0 count
  close_handshaker before-diagnostic-launch || return 1
  capture_common
  while :; do
    attempt=$((attempt+1))
    info "正在启动 Mac 诊断版. 如 macOS 显示打开确认, 请允许打开这份测试应用."
    run_capture "$scenario_dir/mac/launch-${attempt}.txt" 12 /usr/bin/open -n -a "$app_path" \
      --env HS_USB_DIAGNOSTICS=1 --env "HS_USB_DIAGNOSTIC_RUN_ID=$run_id" \
      --env "HS_USB_LOG_PATH=$scenario_dir/mac/usb-diagnostic.log" || true
    for count in $(jot 25); do
      mac_pid=$(find_pid)
      if [ -n "$mac_pid" ] && mac_diagnostic_event "$mac_pid" 'event=DIAGNOSTIC_CAPABILITIES schema=3 hooks=8 bulkSites=10 fileHooks=2 fileCallbacks=1 '; then
        stop_mac_kind agent "$scenario_dir/mac/launch-$attempt-agent-check" || {
          info "诊断版启动后旧后台助手再次出现. 已保留记录, 本轮暂不开始."; return 1;
        }
        capture_mac_processes "$scenario_dir/mac/launch-$attempt-runtime"
        if awk -F '\t' -v pid="$mac_pid" '$2=="app" && $1!=pid {found=1} END {exit !found}' \
          "$scenario_dir/mac/launch-$attempt-runtime/processes.tsv"; then
          info "诊断版启动后又出现另一份 HandShaker. 已保存其路径, 本轮暂不开始."
          return 1
        fi
        if [ "$(find_pid)" != "$mac_pid" ]; then
          info "Mac 诊断版在准备期间退出或重新启动. 已保留记录, 本轮暂不开始."
          return 1
        fi
        printf 'ready=1\npid=%s\n' "$mac_pid" >"$scenario_dir/mac/preflight.status"
        info "Mac 端检查通过."
        return 0
      fi
      if [ -n "$mac_pid" ] && mac_diagnostic_event "$mac_pid" 'event=(BULK_PATCH_REJECTED|TRANSPORT_HOOK_REJECTED)'; then
        info "当前 Mac 未能加载完整诊断模块. 具体原因已保存, 无需继续插拔测试."
        return 1
      fi
      sleep 1
    done
    prompt_enter "处理 Mac 上的启动提示, 确认安装了包内版本, 然后退出 HandShaker" || return 130
    close_handshaker || break
  done
  info "Mac 诊断模块尚未完整加载. 当前日志会自动打包, 无需继续插拔测试."
  return 1
}
record_usb_change() {
  local label
  label="change-$(date +%s)-$RANDOM"
  mark_event user-usb-change-marked
  record_usb_label "$label" || return 130
  info "已标记 USB 用途变化. 继续按当前阶段的选项操作."
}
prepare_transfer_file() {
  local cache_dir="$HOME/.cache/HandShaker-Diagnostics/$run_id"
  mkdir -p "$cache_dir" || return 1
  test_file="$cache_dir/HandShaker-USB-Test-256MiB.bin"
  info "正在准备一个 256 MiB 测试文件, 完成后会在 Finder 中选中它..."
  run_capture "$scenario_dir/test-file-create.txt" 60 /bin/dd if=/dev/urandom of="$test_file" bs=1048576 count=256 || return 1
  printf 'path=%s\nbytes=%s\npacked_in_logs=no\n' "$test_file" "$(stat -f '%z' "$test_file")" >"$scenario_dir/test-file-info.txt"
  mark_event transfer-file-ready
  /usr/bin/open -R "$test_file" >/dev/null 2>&1 || true
  printf '\n测试文件: %s\n' "$test_file"
}
observe_file_transfer() {
  local answer
  prepare_transfer_file || {
    info "测试文件未能生成, 原因已保存. 可以继续回传本轮连接日志."
    printf 'test-file-generation-failed\n' >"$scenario_dir/transfer-result.txt"; return 0;
  }
  info "现在请用 Mac 的 HandShaker, 将这个文件复制到手机的 Download/下载等可写目录."
  info "等待 HandShaker 显示传输结果, 再回到本窗口."
  info "如果原问题是间歇性掉线, 传输后继续观察到平时出现问题的时段, 再选择结果."
  info "日志会记录实际通道和文件任务速度. 不需要手工计时."
  printf '\n传输结束后输入选项, 再按回车:\n  1. 传输成功\n  2. 传输失败, 但仍保持连接\n  3. 传输中断开或卡死\n  0. 没有完成传输测试\n  M. 标记异常时刻\n  U. 标记刚发生的 USB 用途变化\n'
  while IFS= read -r answer; do
    case "$answer" in
      1) printf 'completed-by-user\n' >"$scenario_dir/transfer-result.txt"; break ;;
      2) printf 'failed-by-user\n' >"$scenario_dir/transfer-result.txt"; break ;;
      3) printf 'disconnected-or-hung\n' >"$scenario_dir/transfer-result.txt"; printf '4\n' >"$scenario_dir/user-result.txt"; break ;;
      0) printf 'not-tested\n' >"$scenario_dir/transfer-result.txt"; break ;;
      m|M) mark_event user-noticed-problem; info "已标记异常时刻. 测试仍在记录, 完成后输入结果选项." ;;
      u|U) record_usb_change || return 130 ;;
      q|Q) return 130 ;;
      *) info "请输入 1, 2, 3, 0, M 或 U, 再按回车. 输入 Q 可提前保存日志并结束." ;;
    esac
  done
  [ -f "$scenario_dir/transfer-result.txt" ] || return 130
  mark_event "transfer-user-result value=$(cat "$scenario_dir/transfer-result.txt")"
}
observe_usb() {
  local answer done=0
  mark_event observation-start
  info "请在手机上允许 USB 配件访问和连接确认(如有弹窗). 已授权且没有弹窗时可继续."
  info "保持原来的 USB 用途. 如果掉线, 先保留现场, 不要反复插拔."
  info "确认 Mac 已显示手机文件后, 再选择开始传输测试."
  printf '\n请输入选项, 再按回车:\n  1. Mac 已连接, 开始复制测试文件\n  2. 连接失败或出现异常, 保存现场\n  M. 标记异常时刻, 继续观察\n  U. 标记刚发生的 USB 用途变化\n'
  while IFS= read -r answer; do
    case "$answer" in
      1)
        printf '3\n' >"$scenario_dir/user-result.txt"
        mark_event connection-confirmed-by-user
        observe_file_transfer || return $?
        done=1; break ;;
      2)
        choice "$scenario_dir/user-result.txt" '实际表现最接近哪一项?' '0,1,2,4,5' \
          '1. 手机和 Mac 都没有连接成功' '2. 手机显示电脑已确认, Mac 仍未连接' \
          '4. 曾经连上, 随后断开或反复重连' '5. Mac 转彩球或卡死' '0. 没有观察清楚' || return 130
        printf 'not-tested-connection-issue\n' >"$scenario_dir/transfer-result.txt"
        done=1; break ;;
      m|M) mark_event user-noticed-problem; info "已标记异常时刻. 继续观察, 或输入 2 保存现场." ;;
      u|U) record_usb_change || return 130 ;;
      q|Q) return 130 ;;
      *) info "请输入 1, 2, M 或 U, 再按回车. 输入 Q 可提前保存日志并结束." ;;
    esac
  done
  [ "$done" = 1 ] || return 130
  mark_event observation-end
}
record_usb_dialog() {
  [ "$(cat "$scenario_dir/user-result.txt" 2>/dev/null)" = 4 ] || return 0
  choice "$scenario_dir/usb-dialog.txt" '断开前后, 手机的"仅充电/文件传输"选择框是什么情况? 记不清可选 0.' '0,1,2,3,4' \
    '1. 没有看到这个选择框' '2. 出现后自动消失' '3. 手动关闭过选择框' \
    '4. 在选择框中选过 USB 用途' '0. 没有注意 / 不确定' || return 130
  mark_event "usb-dialog-observation option=$(cat "$scenario_dir/usb-dialog.txt") source=user"
}
observe() {
  local answer
  mark_event observation-start
  info "正在持续记录. 操作没有倒计时, 完成观察后输入 1 并按回车."
  info "输入 M 并按回车可标记异常时刻; 输入 Q 可提前保存日志并结束."
  while IFS= read -r answer; do
    case "$answer" in
      1) mark_event observation-end; return 0 ;;
      m|M) mark_event user-noticed-problem; info "已标记异常时刻." ;;
      q|Q) return 130 ;;
      *) info "完成观察后输入 1 并按回车." ;;
    esac
  done
  return 130
}

capture_ok() {
  [ -s "$1" ] && grep -qx 'exit_code=0' "$1.meta" 2>/dev/null
}
stream_has_records() {
  local pattern="$1" file
  shift
  for file in "$@"; do
    [ -s "$file" ] || continue
    # A disconnect or normal collector shutdown may leave a nonzero exit code.
    grep -q '^start_epoch=' "$file.meta" 2>/dev/null || continue
    LC_ALL=C grep -Eq "$pattern" "$file" && return 0
  done
  return 1
}
postflight_trace_available() {
  local file label meta
  for file in "$scenario_dir/android/"handshaker-after*.log "$scenario_dir/android/"handshaker-after*.log.previous \
    "$scenario_dir/android/"internal-after*.log "$scenario_dir/android/"internal-after*.log.previous; do
    [ -s "$file" ] || continue
    label=${file##*/}
    case "$label" in
      handshaker-*) label=${label#handshaker-}; label=${label/.log/}; meta="$scenario_dir/android/pull-$label.txt.meta" ;;
      *) meta="$file.meta" ;;
    esac
    grep -qx 'exit_code=0' "$meta" 2>/dev/null || continue
    grep -Fq "run=$run_id " "$file" && return 0
  done
  return 1
}
complete_android_capture() {
  local need_state=0 need_trace=0
  [ ! -f "$scenario_dir/android/capture-retry.txt" ] || return 0
  if ! capture_ok "$scenario_dir/android/getprop-after.txt" || \
    ! capture_ok "$scenario_dir/android/dumpsys-usb-after.txt"; then need_state=1; fi
  postflight_trace_available || need_trace=1
  merge_logs
  write_android_sequence_report
  if awk -F '\t' 'NR>1 && $5>0 {found=1} END {exit !found}' "$scenario_dir/android-event-sequence.tsv"; then need_trace=1; fi
  [ "$need_state$need_trace" != 00 ] || return 0
  adb_online || return 0
  info "正在补收尚未取得的手机记录, 请保持连接, 无需重复测试."
  printf 'state=%s\ntrace=%s\nattempts=1\n' "$need_state" "$need_trace" >"$scenario_dir/android/capture-retry.txt"
  mark_event "android-capture-retry state=$need_state trace=$need_trace"
  [ "$need_state" != 1 ] || capture_android_state after-retry
  [ "$need_trace" != 1 ] || pull_android_logs after-retry
  return 0
}
collect_after() {
  local count
  mark_event collection-begin
  info "正在保存 Mac 的 USB 状态和线程信息..."
  capture_usb after
  capture_sample final
  capture_mac_files
  mac_pid=$(find_pid)
  if [ -n "$mac_pid" ]; then
    run_capture "$scenario_dir/mac/vmmap-after.txt" 15 vmmap -summary "$mac_pid" || true
    run_capture "$scenario_dir/mac/lsof-after.txt" 12 lsof -p "$mac_pid" || true
  fi
  if ! adb_online; then
    info "手机的调试连接已断开. Mac 日志已保留, 正在等待调试连接自动恢复."
    for count in 1 2 3 4 5; do sleep 2; adb_online && break; done
  fi
  if ! adb_online; then
    mark_event retrieval-replug-requested
    info "正式观察已经结束. 下面的插拔只用于取回日志, 不需要重新测试."
    close_handshaker || true
    prompt_enter "拔下数据线再插回, 解锁手机并允许 USB 调试" || return 130
    for count in 1 2 3 4 5; do adb_online && break; sleep 2; done
  fi
  if adb_online; then
    info "正在取回手机末尾日志和配置..."
    capture_android_state after
    pull_android_logs after
    adb_capture "$scenario_dir/android/logcat-tail.txt" 20 logcat -d -b all -t 12000 -v epoch || true
    adb_capture "$scenario_dir/android/kernel-usb.txt" 8 shell dmesg || true
    complete_android_capture
  else
    printf 'Android pull unavailable; retained live logcat and Mac evidence.\n' >"$scenario_dir/android/postflight-error.txt"
    info "调试连接仍未恢复. 会保留已取得的日志, 并在摘要中注明缺失项."
  fi
}
merge_logs() {
  local file
  {
    for file in "$scenario_dir/mac/usb-diagnostic.log.previous" "$scenario_dir/mac/usb-diagnostic.log"; do
      [ ! -f "$file" ] || cat "$file"
    done
  } | awk '!seen[$0]++' >"$scenario_dir/mac-events.txt"
  {
    for file in "$scenario_dir/android/"handshaker-*.log.previous "$scenario_dir/android/"handshaker-*.log \
      "$scenario_dir/android/preflight-log.txt" "$scenario_dir/android/"internal-*.log.previous "$scenario_dir/android/"internal-*.log \
      "$scenario_dir/android/"logcat-*.txt "$scenario_dir/android/live/"*.txt; do
      [ ! -f "$file" ] || cat "$file"
    done
  } | awk -v run="$run_id" '
    index($0,"run=" run " ") {
      # Strip logcat prefixes so internal, external and live copies deduplicate.
      if (match($0, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T/)) $0=substr($0,RSTART)
      if (!seen[$0]++) print
    }' >"$scenario_dir/android-events.txt"
}
write_android_sequence_report() {
  # Check only each observed session span, without claiming its ends are complete.
  awk '
    BEGIN {OFS="\t"; print "session","first","last","events","missing_between"}
    {
      session=""; sequence=""
      for(i=1;i<=NF;i++) {
        if($i ~ /^session=/) session=substr($i,9)
        if($i ~ /^eventSequence=[0-9]+$/) sequence=substr($i,15)+0
      }
      if(session=="" || sequence=="" || seen[session,sequence]++) next
      if(!(session in count)) {order[++n]=session; first[session]=sequence; last[session]=sequence}
      count[session]++
      if(sequence<first[session]) first[session]=sequence
      if(sequence>last[session]) last[session]=sequence
    }
    END {for(i=1;i<=n;i++) {s=order[i]; print s,first[s],last[s],count[s],last[s]-first[s]+1-count[s]}}
  ' "$scenario_dir/android-events.txt" >"$scenario_dir/android-event-sequence.tsv"
}
count_event() { awk -v pattern="$1" '$0 ~ pattern {n++} END {print n+0}' "$2"; }
scope_events() {
  local start end offset="" before after phone
  start=$(awk -F '\t' '$3=="connection-window-start" {print $2; exit}' "$scenario_dir/user-events.tsv" 2>/dev/null)
  if [ -z "$start" ]; then start=$(awk -F '\t' '$3 ~ /^observation-start/ {print $2; exit}' "$scenario_dir/user-events.tsv" 2>/dev/null); fi
  end=$(awk -F '\t' '$3=="observation-end" {print $2; exit}' "$scenario_dir/user-events.tsv" 2>/dev/null)
  : >"$scenario_dir/mac-observation-events.txt"; : >"$scenario_dir/android-observation-events.txt"
  printf 'start_epoch=%s\nend_epoch=%s\n' "$start" "$end" >"$scenario_dir/observation-scope.txt"
  [ -n "$start" ] && [ -n "$end" ] || return 0
  before=$(awk -F= '$1=="mac_before_epoch" {print $2}' "$scenario_dir/android/clock-before.txt" 2>/dev/null)
  after=$(awk -F= '$1=="mac_after_epoch" {print $2}' "$scenario_dir/android/clock-before.txt" 2>/dev/null)
  phone=$(awk 'NR==1 && $1 ~ /^[0-9]+$/ {print $1}' "$scenario_dir/android/time-before.txt" 2>/dev/null)
  if [ -n "$before" ] && [ -n "$after" ] && [ -n "$phone" ]; then
    offset=$(awk -v a="$before" -v b="$after" -v p="$phone" 'BEGIN {printf "%.0f", (a+b)*500-p*1000}')
    printf 'android_offset_ms=%s\nclock_uncertainty_ms=%s\n' "$offset" "$(((after-before)*500+1000))" >>"$scenario_dir/observation-scope.txt"
  fi
  awk -v first="$start" -v last="$end" '
    {for (i=1;i<=NF;i++) if ($i ~ /^wallMs=/) {t=substr($i,8)+0; if (t>=first*1000 && t<last*1000+1000) print; break}}
  ' "$scenario_dir/mac-events.txt" >"$scenario_dir/mac-observation-events.txt"
  if [ -n "$offset" ]; then
    awk -v first="$start" -v last="$end" -v offset="$offset" '
      {for (i=1;i<=NF;i++) if ($i ~ /^wallMs=/) {t=substr($i,8)+offset; if (t>=first*1000 && t<last*1000+1000) print; break}}
    ' "$scenario_dir/android-events.txt" >"$scenario_dir/android-observation-events.txt"
  fi
}
generate_configuration_summary() {
  local label file
  {
    printf 'USB 配置记录\n\n手机界面用途由用户选择记录, 不从底层 functions 推断.\n'
    printf '界面选项: 0=未知, 1=仅充电/不传输数据, 2=文件传输/Android Auto, 3=照片/PTP, 4=USB网络共享, 5=其他.\n'
    printf 'persist.* 是系统持久属性, 不保证等于设置界面的默认 USB 用途.\n'
    printf 'sys.usb.config 是请求配置, sys.usb.state 是实际状态; 两者不同只记录为切换证据.\n'
    printf 'cmd.screen_unlocked_functions 是系统可读取的解锁后默认功能. unsupported 表示命令不支持, unknown 表示未取得值.\n'
    printf 'MTP 不是 HandShaker AOA 的必要条件. USB 重新枚举不单独认定为异常断连.\n\n'
    for file in "$scenario_dir/"usb-label-*.txt; do
      [ -f "$file" ] || continue
      printf '%s: %s\n' "${file##*/}" "$(cat "$file")"
    done
    for label in initial before-install before after after-retry; do
      [ "$label" != after-retry ] || [ -f "$scenario_dir/android/usb-config-$label.txt" ] || continue
      printf '\n阶段 %s:\n' "$label"
      file="$scenario_dir/android/usb-config-$label.txt"
      if [ -f "$file" ]; then cat "$file"; else printf 'USB 配置未取得.\n'; fi
    done
    printf '\n底层 USB 配置变化(时间以 Mac 为准, 不自动判断是否人为切换):\n'
    if [ -f "$scenario_dir/android/usb-config-changes.txt" ]; then cat "$scenario_dir/android/usb-config-changes.txt"; else printf '未取得连续配置记录.\n'; fi
    printf '\n手机 USB 广播和配件权限:\n'
    grep -E 'event=(USB_STATE |ACCESSORY_PERMISSION )' "$scenario_dir/android-events.txt" || true
    printf '\n用户操作时间:\n'
    grep -E 'phone-ui-usb-label|user-usb-change|usb-actions|usb-dialog|usb-gate|connection-window|observation-|transfer-user' "$scenario_dir/user-events.tsv" 2>/dev/null || true
    if [ -f "$scenario_dir/usb-dialog.txt" ]; then
      printf '\n掉线时手机 USB 用途选择框: %s\n选项: 0=不确定, 1=未见, 2=自动消失, 3=手动关闭, 4=手动选用途.\n' "$(cat "$scenario_dir/usb-dialog.txt")"
    fi
    printf '\nMac 实际链路快照:\n'
    for label in connected before after; do
      file="$scenario_dir/mac/link-$label.txt"
      [ ! -f "$file" ] || { printf '\n%s\n' "$label"; cat "$file"; }
    done
  } >"$scenario_dir/usb-configuration-summary.txt"
}
generate_transfer_summary() {
  # Keep one row per file task, including tasks without a terminal callback.
  awk '
    BEGIN {OFS="\t"; print "fileTask","direction","transport","fileBytes","completedBytes","elapsedMs","averageMiBps","status","errorDomain","errorCode"}
    /event=FILE_(QUEUED|BEGIN|PROGRESS|END)/ {
      delete f
      for(i=1;i<=NF;i++) {p=index($i,"="); if(p) f[substr($i,1,p-1)]=substr($i,p+1)}
      id=f["fileTask"]; if(id=="") next
      if(!(id in seen)) {order[++n]=id; seen[id]=1}
      # Ignore late progress after a completed callback.
      if(ended[id]) next
      direction[id]=f["direction"]; transport[id]=f["transport"]; size[id]=f["fileBytes"]; bytes[id]=f["completedBytes"]
      if(f["elapsedMs"]!="") elapsed[id]=f["elapsedMs"]
      status[id]="incomplete"; rate[id]="unknown"
      if(f["event"]=="FILE_END") {ended[id]=1; status[id]=f["status"]; rate[id]=f["averageMiBps"]; domain[id]=f["errorDomain"]; code[id]=f["errorCode"]}
    }
    END {for(i=1;i<=n;i++) {id=order[i]; print id,direction[id],transport[id],size[id],bytes[id],(elapsed[id]!=""?elapsed[id]:"unknown"),rate[id],status[id],(domain[id]!=""?domain[id]:"unknown"),(code[id]!=""?code[id]:"unknown")}}
  ' "$scenario_dir/mac-observation-events.txt" >"$scenario_dir/file-transfers.tsv"
  {
    printf '文件传输结果\n\n'
    printf '测速从该文件请求实际发出时开始, 到原客户端完成回调为止. 不计入准备, 授权和等待用户操作的时间.\n'
    printf '只为成功完成, 字节数核对一致且时间有效的任务显示平均 MiB/s. 1 MiB = 1048576 字节.\n'
    printf 'USB-AOA 和 Wi-Fi 按实际设备通道分别记录. Bulk 抽样日志不能直接相加当作文件字节数.\n'
    printf 'incomplete 表示缺少结束回调, 不能据此单独认定传输失败.\n\n'
    awk -F '\t' 'NR>1 {
      direction=($2=="Mac-to-Android" ? "Mac 到手机" : $2=="Android-to-Mac" ? "手机到 Mac" : $2)
      printf "任务: %s\n方向: %s; 通道: %s\n文件字节: %s; 已完成字节: %s\n耗时(ms): %s; 平均速度(MiB/s): %s; 状态: %s\n错误: %s / %s\n\n",$1,direction,$3,$4,$5,$6,$7,$8,$9,$10
      n++
    } END {if(!n) print "未取得正式窗口内的单文件任务记录, 本轮不能提供可靠的文件速度."}' "$scenario_dir/file-transfers.tsv"
    if [ -f "$scenario_dir/transfer-result.txt" ]; then printf '用户反馈: %s\n' "$(cat "$scenario_dir/transfer-result.txt")"; fi
    grep 'event=FILE_DIAGNOSTIC_UNAVAILABLE' "$scenario_dir/mac-observation-events.txt" || true
  } >"$scenario_dir/transfer-summary.txt"
}
coverage_row() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$scenario_dir/capture-coverage.tsv"
}
generate_capture_coverage() {
  local formal=0 postflight=0 state_label=after gaps sequence_count missing limited stage
  [ -n "$out_dir" ] && [ "${scenario_dir##*/}" = usb ] || return 0
  printf 'item\tstatus\tevidence\n' >"$scenario_dir/capture-coverage.tsv"
  grep -q $'\tconnection-window-start$' "$scenario_dir/user-events.tsv" 2>/dev/null && formal=1
  grep -q $'\tcollection-begin$' "$scenario_dir/user-events.tsv" 2>/dev/null && postflight=1
  stage=$(cat "$scenario_dir/round-status.txt" 2>/dev/null || printf unknown)
  if [ -s "$out_dir/common/script-info.txt" ] && [ -s "$out_dir/common/diagnostic-manifest.txt" ] && \
    capture_ok "$out_dir/common/system.txt"; then
    coverage_row '版本与系统' collected 'common/script-info.txt, diagnostic-manifest.txt, system.txt'
  else coverage_row '版本与系统' missing '未取得完整的版本清单或系统信息'; fi
  if capture_ok "$scenario_dir/mac/timeline/usb-00000.txt"; then
    coverage_row 'Mac USB 枚举与拓扑' collected 'mac/timeline/, mac/usb-timeline.txt'
  else coverage_row 'Mac USB 枚举与拓扑' missing '首次 USB 快照未成功取得'; fi
  if grep -q 'android-state-begin label=before-install' "$scenario_dir/user-events.tsv" 2>/dev/null; then
    if capture_ok "$scenario_dir/android/getprop-before-install.txt" && \
      capture_ok "$scenario_dir/android/dumpsys-usb-before-install.txt" && \
      capture_ok "$scenario_dir/android/package-before-install.txt"; then
      coverage_row '手机初始配置与原版本' collected 'android/*before-install*'
    else coverage_row '手机初始配置与原版本' missing '部分初始配置或原应用记录未取得'; fi
  else coverage_row '手机初始配置与原版本' not-reached '未进入初始配置采集'; fi
  if grep -q 'event=PERMISSIONS ' "$scenario_dir/android-events.txt" 2>/dev/null || \
    grep -q 'event=PERMISSIONS ' "$scenario_dir/android/"permissions-*.txt 2>/dev/null; then
    coverage_row '手机授权状态' collected 'android/permissions-*.txt; 已记录实际状态, 不等同于全部授权'
  elif [ "$formal" = 1 ]; then coverage_row '手机授权状态' missing '正式连接前未取得权限事件'
  else coverage_row '手机授权状态' not-reached '未取得授权检查结果'; fi
  if [ "$formal" = 1 ]; then
    if grep -q $'\tobservation-end$' "$scenario_dir/user-events.tsv" 2>/dev/null; then
      coverage_row '正式连接窗口' collected 'user-events.tsv; 开始和结束标记均已保存'
    else coverage_row '正式连接窗口' missing '已有开始标记, 未取得观察结束标记'; fi
    if grep -q '^ready=1$' "$scenario_dir/mac/preflight.status" 2>/dev/null && \
      grep -Fq "run=$run_id " "$scenario_dir/mac-events.txt"; then
      coverage_row 'Mac 诊断模块与事件' collected 'mac/preflight.status, mac-events.txt'
    else coverage_row 'Mac 诊断模块与事件' missing '模块预检或本轮 Mac 事件未取得'; fi
    if [ -s "$scenario_dir/android-observation-events.txt" ]; then
      coverage_row '手机正式连接事件' collected 'android-observation-events.txt; 结合授权, 读写和协议事件判断失败阶段'
    else coverage_row '手机正式连接事件' missing '正式窗口内未取得可对齐的手机事件'; fi
    if stream_has_records '^[[:space:]]*[0-9]{10}\.[0-9]+[[:space:]]' "$scenario_dir/android/logcat-tail.txt" "$scenario_dir/android/live/"logcat-*.txt; then
      coverage_row '手机系统 USB 与退出事件采集' collected 'android/live/, logcat-tail.txt; 系统输出范围内的记录, 不保证包含未公开的系统调用'
    else coverage_row '手机系统 USB 与退出事件采集' missing '未取得带时间戳的系统日志, USB 模式切换调用方和进程退出证据可能不足'; fi
    if stream_has_records '^[0-9]{4}-[0-9]{2}-[0-9]{2} ' "$scenario_dir/mac/"system-log-live-*.txt; then
      coverage_row 'Mac 系统 USB 事件采集' collected 'mac/system-log-live-*.txt; 正常停止采集产生的非零退出码不单独判断为失败'
    else coverage_row 'Mac 系统 USB 事件采集' limited '未取得系统事件, 需结合应用诊断和 USB 拓扑记录'; fi
    if grep -q '^Call graph:' "$scenario_dir/mac/"sample-*.txt 2>/dev/null; then
      coverage_row 'Mac 线程采样' collected 'mac/sample-*.txt; 与 Bulk 提交, 返回及等待记录共同分析'
    else coverage_row 'Mac 线程采样' limited '未取得调用栈采样, 可能因进程已退出或系统采样受限'; fi
    if grep -q '^android_offset_ms=' "$scenario_dir/observation-scope.txt"; then
      coverage_row '两端时钟对齐' collected 'observation-scope.txt; 对齐误差仍需纳入时序判断'
    else coverage_row '两端时钟对齐' missing '无法可靠比较两端事件先后'; fi
  elif [ "$stage" = completed ]; then
    coverage_row '正式连接窗口' missing '流程显示已结束, 但没有正式连接开始标记'
  else
    coverage_row '正式连接窗口' not-reached '正式连接尚未开始, 已有准备阶段记录仍可用于分析'
  fi
  if [ "$postflight" = 1 ]; then
    if capture_ok "$scenario_dir/android/getprop-after-retry.txt" && \
      capture_ok "$scenario_dir/android/dumpsys-usb-after-retry.txt"; then state_label=after-retry; fi
    if capture_ok "$scenario_dir/android/getprop-$state_label.txt" && \
      capture_ok "$scenario_dir/android/dumpsys-usb-$state_label.txt"; then
      coverage_row '手机末尾 USB 配置' collected "android/*$state_label*"
    else coverage_row '手机末尾 USB 配置' missing '末尾配置未取得, 已保留连续采集和其他现场'; fi
    if postflight_trace_available; then
      coverage_row '手机持久诊断日志' collected 'android/handshaker-after*.log 或 internal-after*.log'
    else coverage_row '手机持久诊断日志' missing '本轮持久日志未取回, 需结合已保存的实时日志'; fi
    if capture_ok "$scenario_dir/android/exit-info-after.txt" || \
      capture_ok "$scenario_dir/android/exit-info-after-retry.txt"; then
      coverage_row '手机进程退出记录' collected 'android/exit-info-after*.txt; 没有退出条目也属于已取得的结果'
    else coverage_row '手机进程退出记录' limited '系统未提供可读取的退出记录'; fi
  else coverage_row '末尾取回' not-reached '未完成末尾采集, 查看中断现场和实时日志'; fi
  if [ "$(cat "$scenario_dir/transfer-result.txt" 2>/dev/null)" = not-tested ]; then
    coverage_row '单文件传输' not-reached '用户选择没有完成传输测试, 不据此判断日志采集失败'
  elif [ -f "$scenario_dir/test-file-info.txt" ]; then
    if [ "$(cat "$scenario_dir/transfer-result.txt" 2>/dev/null)" = completed-by-user ]; then
      if grep -q 'event=FILE_END.*status=completed.*averageMiBps=[0-9]' "$scenario_dir/mac-observation-events.txt"; then
        coverage_row '单文件传输结果' collected 'file-transfers.tsv; 字节计数与完成回调可核验, 未进行文件内容哈希比对'
      else coverage_row '单文件传输结果' missing '用户反馈成功, 但没有可核验的完成和速度记录'; fi
    elif grep -Eq 'event=FILE_(QUEUED|BEGIN|PROGRESS|END)' "$scenario_dir/mac-observation-events.txt"; then
      coverage_row '单文件传输现场' collected 'file-transfers.tsv; 任务未完成时需检查最后进度和阻塞记录'
    else coverage_row '单文件传输现场' limited '生成了测试文件, 但没有文件任务事件; 不能据此判断是否已发起传输'; fi
  else coverage_row '单文件传输' not-reached '未进入文件测试'; fi
  write_android_sequence_report
  gaps=$(awk -F '\t' 'NR>1 {n+=$5} END {print n+0}' "$scenario_dir/android-event-sequence.tsv")
  sequence_count=$(awk 'END {print NR-1}' "$scenario_dir/android-event-sequence.tsv")
  if [ "$gaps" -gt 0 ]; then coverage_row '手机事件编号连续性' missing "已捕获编号范围内缺少 $gaps 条事件, 查看 android-event-sequence.tsv"
  elif [ "$sequence_count" -gt 0 ]; then coverage_row '手机事件编号连续性' collected '已捕获的编号范围内无缺号; 不据此推断首尾完整'
  else coverage_row '手机事件编号连续性' limited '尚无可核验的事件序号'; fi
  if [ -f "$scenario_dir/android/kernel-usb.txt.meta" ] && ! capture_ok "$scenario_dir/android/kernel-usb.txt"; then
    coverage_row '手机内核日志' limited 'Android 系统限制或未提供; 查看 android/kernel-usb.txt, 无需为此重新测试'
  fi
  if grep -Eq '^cmd\.[^=]+=unsupported$' "$scenario_dir/android/"usb-config-*.txt 2>/dev/null; then
    coverage_row 'USB 查询命令' limited '部分命令不受此系统支持; 可结合 getprop, dumpsys USB 和用户记录的界面用途分析'
  fi
  if [ "$(cat "$scenario_dir/user-result.txt" 2>/dev/null)" = 4 ]; then
    if [ -s "$scenario_dir/usb-dialog.txt" ] && [ "$(cat "$scenario_dir/usb-dialog.txt")" != 0 ]; then
      coverage_row '掉线时的 USB 用途弹窗' collected 'usb-dialog.txt; 用户观察与系统事件分开记录'
    else coverage_row '掉线时的 USB 用途弹窗' limited '没有取得明确的用户观察, 不从日志推断是否手动操作'; fi
  fi
  missing=$(awk -F '\t' '$2=="missing" {n++} END {print n+0}' "$scenario_dir/capture-coverage.tsv")
  limited=$(awk -F '\t' '$2=="limited" {n++} END {print n+0}' "$scenario_dir/capture-coverage.tsv")
  printf 'missing=%s\nlimited=%s\nstage=%s\n' "$missing" "$limited" "$stage" >"$scenario_dir/capture-coverage-status.txt"
  {
    printf 'HandShaker 日志检查\n'
    if [ "$stage" != completed ]; then printf '本轮提前结束, 已保存进行到当前步骤的记录.\n'
    elif [ "$missing" -gt 0 ]; then printf '部分关键记录未取得, 已保留可用现场.\n'
    else printf '本轮关键诊断记录已取得.\n'; fi
    printf '\n流程状态: %s\n关键缺失项: %s\n系统受限或未确认项: %s\n\n' "$stage" "$missing" "$limited"
    awk -F '\t' 'NR>1 && ($2=="missing" || $2=="limited") {printf "- %s: %s.\n",$1,$3}' "$scenario_dir/capture-coverage.tsv"
    printf '\n请先回传本轮 ZIP, 无需为了补日志自行重复卸载安装或重做测试.\n'
    printf '日志取得完整与故障原因已确定是两件事. 若原问题没有在本轮出现, 这些记录只能说明本轮表现.\n'
    printf '详细采集状态见 usb/capture-coverage.tsv, 手机事件连续性见 usb/android-event-sequence.tsv.\n'
  } >"$out_dir/日志检查.txt"
  return 0
}
generate_summary() {
  local result="unknown" action="unknown" missing="" conclusion="" handshakes bulk_errors excessive usb_off
  local round_result="$workflow_result" mac_events="$scenario_dir/mac-observation-events.txt" android_events="$scenario_dir/android-observation-events.txt"
  [ ! -f "$scenario_dir/round-status.txt" ] || round_result=$(cat "$scenario_dir/round-status.txt")
  [ ! -f "$scenario_dir/user-result.txt" ] || result=$(cat "$scenario_dir/user-result.txt")
  [ ! -f "$scenario_dir/usb-actions.txt" ] || action=$(cat "$scenario_dir/usb-actions.txt")
  merge_logs
  scope_events
  generate_configuration_summary
  generate_transfer_summary
  generate_capture_coverage
  handshakes=$(count_event 'event=HANDSHAKE_END.*result=<response-present>' "$mac_events")
  bulk_errors=$(count_event 'event=BULK_END.*rc=-[0-9]+' "$mac_events")
  excessive=$(count_event 'event=BULK_PENDING.*deadlineExceeded=1' "$mac_events")
  usb_off=$(count_event 'event=USB_STATE connected=false' "$android_events")
  [ -f "$scenario_dir/mac/preflight.status" ] || missing="$missing Mac诊断预检未通过;"
  [ -f "$scenario_dir/android/preflight.status" ] || missing="$missing Android诊断预检未通过;"
  [ -s "$scenario_dir/android/permissions-ready.txt" ] || missing="$missing 手机必要权限未确认;"
  grep -q 'event=INPUT_\|event=SSP_' "$android_events" || missing="$missing 正式观察期间手机流/协议事件未取得;"
  [ ! -f "$scenario_dir/android/postflight-error.txt" ] || missing="$missing 手机末尾状态/持久日志未拉取;"
  grep -q '^android_offset_ms=' "$scenario_dir/observation-scope.txt" || missing="$missing 手机时钟未对齐, 未自动统计其断开次数;"
  if [ -f "$scenario_dir/observation-interrupted.txt" ]; then missing="$missing 观察窗口由中断收尾关闭;"; fi
  if grep -Eq '^missing=[1-9][0-9]*$' "$scenario_dir/capture-coverage-status.txt" 2>/dev/null; then
    missing="$missing 采集完整性检查发现关键缺项, 详见日志检查.txt;"
  fi
  if [ "$(cat "$scenario_dir/transfer-result.txt" 2>/dev/null)" = completed-by-user ] && \
    ! grep -q 'event=FILE_END.*averageMiBps=[0-9]' "$mac_events"; then missing="$missing 用户反馈传输完成, 但没有可核验的单文件速度;"; fi
  if [ "$round_result" = android-install-failed ]; then
    conclusion="Android 安装失败, 新 APK 未安装成功, 正式连接尚未开始. 请核对卸载和安装日志."
  elif [ "$round_result" = android-uninstall-failed ]; then
    conclusion="旧 Android 应用未能完整卸载, 本轮未进入正式连接测试."
  elif [ "$round_result" = user-declined-uninstall ]; then
    conclusion="用户选择保留现有 Android 应用, 本轮只保留了准备阶段的日志."
  elif [ "$round_result" != completed ]; then
    conclusion="正式流程未完整结束. 请先查看流程状态和缺失项, 保留现有证据."
  elif [ "$excessive" -gt 0 ]; then
    conclusion="记录到带超时参数的 USB 传输长时间未返回. 需按 transfer 编号核对后续完成记录, 不能仅凭采样判断永久挂起."
  elif [ "$bulk_errors" -gt 0 ]; then
    conclusion="记录到 USB 传输错误或超时返回. 需按 connection/sid 对齐手机读取与 SSP 解码, 判断发生在哪个请求."
  elif [ "$result" = 4 ]; then
    conclusion="用户反馈连接后断开. 请结合用户操作, AOA重新枚举和 SystemUI 的 USB 模式选择记录确认触发顺序."
  elif [ "$result" = 3 ]; then
    conclusion="用户反馈本轮 Mac 连接正常. USB_STATE变化可能来自正常AOA重新枚举, 不单独判作异常断连."
  elif [ "$handshakes" -gt 0 ]; then
    conclusion="前置 USB 握手已返回响应. 后续连接结果需核对 SSP_PHASE, SSP_SEND, 手机 PACKET_PARSED/DECODE 记录."
  else
    conclusion="尚无足够证据确认完整连接. 请沿 AOA 枚举, 配件授权, 首包与 SSP 流程检查."
  fi
  {
    printf 'HandShaker USB 测试摘要\n\n测试包编号: %s\n运行编号: %s\n脚本修订: %s\nUSB流程状态: %s\n结束清理: %s\n' "$(manifest_value BUNDLE_ID)" "$run_id" "$script_revision" "$round_result" "$cleanup_result"
    printf '用户结果选项: %s\n用户 USB 操作选项: %s\n\n' "$result" "$action"
    printf '用户结果: 0=未观察清楚, 1=两端未连接, 2=手机已确认/Mac未连接, 3=Mac连接正常, 4=连上后断开, 5=Mac卡死.\n'
    printf 'USB操作: 0=不确定, 1=未改用途且未手动插拔, 2=改过USB用途, 3=手动插拔, 4=两者都有.\n\n'
    printf '证据判断: %s\n缺失项: %s\n\n' "$conclusion" "${missing:-未发现上述缺失项}"
    printf '仅统计正式连接窗口, 已去除重复记录:\n握手响应次数: %s\nBulk错误/超时返回次数: %s\n超过超时参数仍等待的快照数: %s\nUSB_STATE=false广播次数: %s\n\n' "$handshakes" "$bulk_errors" "$excessive" "$usb_off"
    printf '文件传输: 请查看 transfer-summary.txt 和 file-transfers.tsv.\nUSB配置: 请查看 usb-configuration-summary.txt.\n\n'
    printf '判断边界:\n- 10Gbps 或未知速率只记录为环境特征, 不自动归因为故障原因.\n- USB模式切换时的重新枚举不等同于异常断线.\n- 无后续日志不等同于没有后续传输; 先核对采集缺失和计数.\n- IN读取等待可能是空闲状态; timeoutMs=0表示调用没有设置超时.\n- 传输错误可能发生在正常清理阶段, 不能仅靠次数定根因.\n\n'
    printf '证据索引:\n*-observation-events.txt: 对齐手机时钟后的正式连接窗口事件.\nmac-events.txt / android-events.txt: 本轮全部去重事件, 包含准备与收集阶段.\nobservation-scope.txt: 统计范围与手机时钟对齐误差.\nmac/shutdown-*/: 各安装路径的旧进程, 后台助手的启动来源和停止结果.\nmac/preexisting/: 启动脚本前已存在的 Mac 日志, 不自动认定为本轮故障.\nmac/: Bulk返回值, SSP阶段, 线程采样, USB拓扑和内核日志.\nandroid/*before-stop*: 脚本主动停止手机 App 之前的退出记录与现场.\nandroid/*before-install*: 卸载安装之前的原应用版本, 权限和持久日志.\nandroid/signing-before-install/: 原 APK 摘要和可读取的 v1 公钥证书; 不含私钥或完整 APK.\nandroid/*interrupted*: 安装失败或中断时保留的现场.\nusb-configuration-summary.txt: 初始用途, 请求/实际配置, 不支持的命令和切换记录.\nfile-transfers.tsv / transfer-summary.txt: 单文件任务, 实际通道, 完成字节与平均速度.\nandroid/installed-users.tsv / uninstall-consent.txt: 卸载范围与用户选择.\nandroid/: 权限状态, USB functions, SystemUI事件, 读写计数, 阻塞线程, SSP解码, 进程退出原因.\nuser-events.tsv: 正式观察范围, 问题时刻和脚本主动安装/停止的时间.\n*.meta: 采集命令退出码和时限; limit_seconds=0 表示等待用户确认安装, 无固定时限; *.timeout: 命令超时.\n'
  } >"$scenario_dir/diagnosis-summary.txt"
}
finish_usb_runtime() {
  local previous_scenario="$scenario_dir"
  [ "$mac_takeover" = 1 ] || return 0
  scenario_dir="$out_dir/usb"
  [ -f "$out_dir/common/system.txt" ] || capture_common
  if ! grep -qx completed "$scenario_dir/round-status.txt"; then
    info "正在保存中断现场和退出记录..."
    capture_mac_processes "$scenario_dir/mac/interrupted"
    capture_mac_files interrupted
    if [ -n "$android_user" ] && adb_online; then
      capture_android_exit_evidence interrupted
      pull_android_logs interrupted
    fi
  fi
  if grep -q 'connection-window-start' "$scenario_dir/user-events.tsv" 2>/dev/null && \
    ! grep -q $'\tobservation-end$' "$scenario_dir/user-events.tsv"; then
    mark_event observation-end
    printf 'window_closed_by=cleanup-after-interruption\n' >"$scenario_dir/observation-interrupted.txt"
  fi
  mark_event cleanup-begin
  info "正在关闭本轮 HandShaker 和旧后台助手..."
  cleanup_result=completed
  close_handshaker finalize || cleanup_result=mac-stop-failed
  if [ -n "$android_user" ]; then
    if adb_online; then
      stop_android_app finalize || cleanup_result="$cleanup_result;android-stop-failed"
    else
      cleanup_result="$cleanup_result;android-offline-not-stopped"
    fi
  fi
  printf 'status=%s\nandroid_user=%s\nlogin_item_preferences=unchanged\nold_apps_restarted=no\n' "$cleanup_result" "${android_user:-not-selected}" >"$scenario_dir/cleanup-status.txt"
  mark_event "cleanup-end status=$cleanup_result"
  scenario_dir="$previous_scenario"
}
finalize() {
  local exit_code="${1:-0}" pid file archive
  [ "$finalized" = 0 ] || return 0
  finalized=1
  trap - EXIT INT TERM HUP
  [ -n "$out_dir" ] && [ -d "$out_dir" ] || { release_run_lock; return 0; }
  stop_workers
  for file in "$state_dir/children/"*; do
    [ -f "$file" ] || continue
    pid=${file##*/}; terminate_tree "$pid"; wait "$pid" 2>/dev/null || true
  done
  finish_usb_runtime
  # A cancelled APK certificate extraction must not add the APK to the ZIP.
  rm -f "$state_dir/installed-base.apk"
  # Mark collectors interrupted before their metadata writer returned.
  while IFS= read -r -d '' file; do
    grep -q '^exit_code=' "$file" || printf 'exit_code=interrupted\n' >>"$file"
  done < <(find "$out_dir" -type f -name '*.meta' -print0)
  if [ "$exit_code" != 0 ]; then workflow_result="interrupted-or-failed:$exit_code"; fi
  printf 'run=%s\nbundle_id=%s\nscript_revision=%s\nworkflow=%s\nexit_code=%s\ncleanup=%s\nfinished=%s\n' "$run_id" "$(manifest_value BUNDLE_ID)" "$script_revision" "$workflow_result" "$exit_code" "$cleanup_result" "$(date '+%Y-%m-%dT%H:%M:%S%z')" >"$out_dir/run-status.txt"
  [ ! -d "$out_dir/usb" ] || { scenario_dir="$out_dir/usb"; generate_summary; }
  printf '请回传与本文件夹同名的 ZIP. 如 ZIP 未生成, 请在 Finder 中压缩本文件夹后回传.\n流程状态: %s\n' "$workflow_result" >"$out_dir/回传说明.txt"
  archive="${out_dir}.zip"
  printf '\n正在打包已收集的日志, 请稍候...\n'
  if /usr/bin/ditto -c -k --keepParent --norsrc "$out_dir" "$archive"; then
    if [ "$workflow_result" = completed ]; then step '日志已生成' '请回传这一份 ZIP'
    else step '本轮提前结束' '已保存现有日志, 请回传这一份 ZIP'; fi
    printf '\n%s\n\n' "$archive"
    info "只需发送这个 ZIP, 不必逐个挑选日志文件."
    [ ! -f "$out_dir/日志检查.txt" ] || info "$(sed -n '2p' "$out_dir/日志检查.txt")"
    if [ "$mac_takeover" = 1 ]; then
      if [ "$cleanup_result" = completed ]; then
        info "Mac 主程序和旧后台助手已关闭. 需要继续使用时, 从应用程序中重新打开 HandShaker."
      else
        info "部分关闭操作未完成, 状态已写入日志. 请先拔下数据线, 避免继续自动连接."
      fi
    fi
    if [ "$workflow_result" != completed ]; then info "本轮未完整结束, 已取得的日志仍然有用. 请一并回传."; fi
    if [ -t 1 ] && [ "${HANDSHAKER_DIAGNOSTIC_REVEAL_OUTPUT:-1}" = 1 ]; then /usr/bin/open -R "$archive" >/dev/null 2>&1 || true; fi
  else
    info "压缩未完成. 请在 Finder 中压缩下面的文件夹并回传:"
    printf '%s\n' "$out_dir"
  fi
  release_run_lock
}
collect_usb_round() {
  scenario_dir="$out_dir/usb"
  mkdir -p "$scenario_dir/mac/timeline" "$scenario_dir/android/timeline" "$scenario_dir/android/live"
  mark_event script-collection-start
  printf 'checking-mac-installation\n' >"$scenario_dir/round-status.txt"
  start_worker mac_log_monitor
  start_worker usb_monitor
  capture_mac_files preexisting
  capture_mac_processes "$scenario_dir/mac/preexisting-runtime"
  step '1/7' '确认 Mac 诊断版已安装'
  check_mac_installation || return $?
  step '2/7' '连接手机, 保存初始信息'
  mac_takeover=1
  close_handshaker startup || return 1
  printf 'collecting-initial-state\n' >"$scenario_dir/round-status.txt"
  prepare_android || return $?
  step '3/7' '重新安装 Android 诊断版'
  printf 'installing-android\n' >"$scenario_dir/round-status.txt"
  install_android_clean || return $?
  step '4/7' '授予权限, 准备正式连接'
  printf 'checking-permissions\n' >"$scenario_dir/round-status.txt"
  stop_android_app after-install || return 1
  check_android_permissions || return $?
  info "正在保存新版本和授权后的状态..."
  capture_android_state before
  printf 'ready=1\n' >"$scenario_dir/android/preflight.status"
  printf '\n现在请操作: 拔下手机数据线, 保持手机 HandShaker 打开.\n'
  info "检测到拔线后会自动继续, 无需按回车. 先不要插回, 等待下一步提示. 输入 Q 可结束."
  wait_for_usb_state absent || return $?
  prepare_mac || return $?
  capture_usb before
  start_worker sample_monitor
  step '5/7' '正式连接和文件传输'
  mark_event connection-window-start
  printf '\n现在请操作: 插回刚才的数据线, 手机出现 USB 配件授权时选择允许.\n'
  info "检测到手机后会自动继续, 无需按回车. 本轮保留原 USB 用途, 输入 Q 可结束."
  wait_for_usb_state present || return $?
  workflow_result=observing
  printf 'observing\n' >"$scenario_dir/round-status.txt"
  observe_usb || return $?
  step '6/7' '确认本轮 USB 操作'
  choice "$scenario_dir/usb-actions.txt" '正式连接和传输期间, 是否改过 USB 用途或额外拔插数据线?' '0,1,2,3,4' \
    '1. 都没有, 一直保持原状态' '2. 改过手机的 USB 用途' '3. 额外拔插过数据线' '4. 两者都有' '0. 不确定' || return 130
  mark_event "usb-actions-confirmed option=$(cat "$scenario_dir/usb-actions.txt")"
  record_usb_dialog || return $?
  step '7/7' '收集结果并生成日志包'
  info "请保持手机连接, 脚本正在收集本轮记录..."
  collect_after || return $?
  stop_workers
  workflow_result=completed
  printf 'completed\n' >"$scenario_dir/round-status.txt"
}

bonjour_monitor() {
  local index=0
  while [ ! -f "$scenario_dir/.stop" ]; do
    run_capture "$scenario_dir/bonjour-$index.txt" 600 dns-sd -B _handshaker_ssp._tcp local || true
    index=$((index+1))
  done
}
collect_wifi_round() {
  scenario_dir="$out_dir/wifi"
  mkdir -p "$scenario_dir/mac"
  printf 'preparing\n' >"$scenario_dir/round-status.txt"
  step 'Wi-Fi' '无线连接观察'
  prompt_enter "拔下 USB 线, 将手机和 Mac 连到同一 Wi-Fi, 打开两端 HandShaker" || return 130
  capture_common
  start_worker mac_log_monitor
  start_worker sample_monitor
  start_worker bonjour_monitor
  run_capture "$scenario_dir/network-before.txt" 12 scutil --nwi || true
  printf 'observing\n' >"$scenario_dir/round-status.txt"
  observe || return $?
  choice "$scenario_dir/user-result.txt" '无线连接结果?' '0,1,2,3' '1. 正常连接' '2. 无法连接' '3. 连接后断开/卡死' '0. 未观察清楚' || return 130
  run_capture "$scenario_dir/network-after.txt" 12 scutil --nwi || true
  capture_sample final
  stop_workers
  workflow_result=completed
  printf 'completed\n' >"$scenario_dir/round-status.txt"
}
self_test() {
  local fixture previous_state="$state_dir" previous_scenario="$scenario_dir" previous_run="$run_id" previous_out="$out_dir"
  fixture=$(mktemp -d "${TMPDIR:-/tmp}/handshaker-script-test.XXXXXX")
  out_dir="$fixture"
  state_dir="$fixture/state"; mkdir -p "$state_dir/children"
  scenario_dir="$fixture/usb"; run_id=selftest
  mkdir -p "$scenario_dir/mac" "$scenario_dir/android/live"
  # shellcheck disable=SC2016
  run_capture "$fixture/ok.txt" 3 printf '%s\n' 'space and $literal' || return 1
  # shellcheck disable=SC2016
  grep -qx 'space and \$literal' "$fixture/ok.txt" || return 1
  if run_capture "$fixture/timeout.txt" 1 /bin/sleep 20; then return 1; fi
  grep -q 'exit_code=124' "$fixture/timeout.txt.meta" || return 1
  run_capture "$fixture/timeout.txt" 2 printf 'recovered\n' || return 1
  [ ! -f "$fixture/timeout.txt.timeout" ] || return 1
  : >"$scenario_dir/mac/preflight.status"; : >"$scenario_dir/android/preflight.status"
  printf 'requiredReady=true\n' >"$scenario_dir/android/permissions-ready.txt"
  printf '3\n' >"$scenario_dir/user-result.txt"; printf '1\n' >"$scenario_dir/usb-actions.txt"
  printf 'test\t100\tconnection-window-start\ntest\t280\tobservation-end\n' >"$scenario_dir/user-events.tsv"
  printf 'mac_before_epoch=90\nmac_after_epoch=90\n' >"$scenario_dir/android/clock-before.txt"
  printf '90\n' >"$scenario_dir/android/time-before.txt"
  printf 'wallMs=150000 event=HANDSHAKE_END result=<response-present>\n' >"$scenario_dir/mac/usb-diagnostic.log"
  printf 'wallMs=150000 run=selftest event=INPUT_PROGRESS totalBytes=500\nwallMs=95000 run=selftest event=USB_STATE connected=false\nwallMs=300000 run=selftest event=USB_STATE connected=false\n' >"$scenario_dir/android/handshaker-after.log"
  cp "$scenario_dir/android/handshaker-after.log" "$scenario_dir/android/internal-after.log"
  workflow_result=completed; generate_summary
  grep -q '本轮 Mac 连接正常' "$scenario_dir/diagnosis-summary.txt" || return 1
  grep -q 'USB_STATE=false广播次数: 0' "$scenario_dir/diagnosis-summary.txt" || return 1
  [ "$(wc -l <"$scenario_dir/android-events.txt" | tr -d ' ')" = 3 ] || return 1
  printf 'wallMs=200000 event=BULK_PENDING transfer=1 timeoutMs=500 deadlineExceeded=1\n' >>"$scenario_dir/mac/usb-diagnostic.log"
  generate_summary; grep -q '长时间未返回' "$scenario_dir/diagnosis-summary.txt" || return 1
  if printf 'x\n\n2\n' | choice "$fixture/choice.txt" 'choice test' '1,2' '1. A' '2. B' >"$fixture/choice-output.txt"; then
    grep -qx 2 "$fixture/choice.txt" || return 1
  else return 1; fi
  printf '脚本自检通过. 验证记录: %s\n' "$fixture"
  state_dir="$previous_state"; scenario_dir="$previous_scenario"; run_id="$previous_run"; out_dir="$previous_out"
}
main() {
  local mode="${1:---usb}" timestamp output_root="${HANDSHAKER_DIAGNOSTIC_OUTPUT_ROOT:-$HOME/Desktop}"
  case "$mode" in
    --self-test) self_test; return $? ;;
    --help) printf '双击运行 USB 联合测试. 命令行选项: --usb, --wifi, --all, --self-test.\n'; return 0 ;;
    --usb|--wifi|--all) ;;
    *) printf '未知选项. 使用 --help 查看说明.\n' >&2; return 2 ;;
  esac
  umask 077
  acquire_run_lock || return 1
  trap release_run_lock EXIT
  timestamp=$(date '+%Y%m%d-%H%M%S'); run_id="$timestamp-$$-$RANDOM"
  mkdir -p "$output_root"
  out_dir=$(mktemp -d "$output_root/HandShaker-Diagnostics-${timestamp}-XXXXXX") || return 1
  printf '%s\n' "$out_dir" >"$lock_dir/output.txt"
  state_dir="$out_dir/.state"; mkdir -p "$state_dir/children" "$out_dir/common"
  printf '%s\n' "$run_id" >"$out_dir/run-id.txt"
  trap 'finalize $?' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  printf '\nHandShaker 连接测试\n\n'
  info "测试包编号: $(manifest_value BUNDLE_ID). 两端应用版本由脚本自动核对."
  if [ "$mode" != --wifi ]; then
    info "请先完成其他文件传输. 脚本将保存旧日志, 停止两端 App, 再重新安装手机诊断版."
  fi
  info "脚本会等待操作, 测试结束由你选择. 一次只运行这个测试窗口."
  info "看到操作提示或数字选项时再操作, 其他时间等待脚本自动处理."
  info "完成后只需回传一份 ZIP. 中途按 Ctrl+C 也会尽量保存已收集的日志."
  if [ "$mode" != --wifi ]; then
    [ -f "$script_dir/usb_link.awk" ] || { info "测试包缺少 usb_link.awk. 请重新解压完整 ZIP."; return 1; }
    if [ -f "$script_dir/SHA256SUMS.txt" ]; then
      info "正在检查测试包文件是否完整..."
      # shellcheck disable=SC2016
      run_capture "$out_dir/common/package-check.txt" 30 /bin/bash -c 'cd -- "$1" && shasum -a 256 -c SHA256SUMS.txt' _ "$script_dir" || {
        info "测试包校验未通过. 请重新下载并完整解压, 错误信息已保存."; return 1;
      }
    fi
    collect_usb_round || return $?
  fi
  if [ "$mode" = --wifi ] || [ "$mode" = --all ]; then collect_wifi_round || return $?; fi
  info "正在整理回传文件..."
}

if [ "${1:-}" = --library ]; then
  if [ "${BASH_SOURCE[0]}" != "$0" ]; then return 0; else exit 0; fi
fi
main "$@"
