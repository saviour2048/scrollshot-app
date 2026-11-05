#!/bin/bash
# display_monitor.sh — 外接显示器黑屏问题常驻监测
#
# 链路: Mac --USB-C--> Parade Technologies hub --DP alt mode--> AOC LV273HUPR
# 症状: 偶发黑屏, 恢复后鼠标卡顿几秒
#
# 监测原理(全部为免 sudo 的 ioreg/ps/log 读取):
#   1. DP 链路节点:  ioreg -c IOPortTransportStateDisplayPort (Active/HPD_State/LinkRate/LaneCount/EDIDChanged)
#   2. PD 端口计数器: ioreg -c AppleSmartBattery 的 PortControllerInfo (Attach/Detach/HardReset/...)
#   3. USB 拓扑:     ioreg -p IOUSB 全树 hash (hub 复位 = 树变化 / 设备 registry id 变化)
#   4. WindowServer CPU: 佐证"恢复后鼠标卡顿"
# 状态任意变化 => 事件: 记 events.log + 抓深快照(含 log show 回捞 10 分钟系统日志)
#
# 用法:
#   display_monitor.sh run        常驻监测主循环 (由 launchd 拉起, 不要手动重复跑)
#   display_monitor.sh once       打印当前完整快照 (验证数据源是否正常)
#   display_monitor.sh status     监测进程状态 / 最近事件 / 快照列表
#   display_monitor.sh install    安装 LaunchAgent (开机自启 + 崩溃自拉起)
#   display_monitor.sh uninstall  卸载 LaunchAgent
#
# 日志目录: ~/Library/Logs/DisplayMonitor/
#   events.log      事件时间线 (每次状态变迁一条)
#   heartbeat.log   每 60 秒一行 (确认监测存活 + 慢速漂移)
#   snapshots/      事件深快照目录 (保留最近 50 个)

set -u

LABEL="com.scrollshot.displaymonitor"
LOG_DIR="$HOME/Library/Logs/DisplayMonitor"
SNAP_DIR="$LOG_DIR/snapshots"
EVENTS_LOG="$LOG_DIR/events.log"
HEARTBEAT_LOG="$LOG_DIR/heartbeat.log"
POLL_INTERVAL=1
HEARTBEAT_EVERY=60
SNAP_KEEP=50
SNAP_THROTTLE_SEC=15   # 抖动风暴期间不重复抓深快照, 只记事件行

mkdir -p "$SNAP_DIR"

now_ms() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
now_s()  { date +%s; }
ts()     { date '+%Y-%m-%d %H:%M:%S'; }

# ---------- 采样通道 ----------

# DP 链路: 节点 registry id 列表 + 关键属性 (顺序稳定, 整体 diff)
sample_dp() {
  {
    ioreg -rc IOPortTransportStateDisplayPort -w0 2>/dev/null | grep -oE 'id 0x[0-9a-f]+'
    ioreg -rw0 -c IOPortTransportStateDisplayPort -l 2>/dev/null | \
      grep -E '"(Active|HPD_State|HPD_StateDescription|LinkRate|LinkRateDescription|LaneCount|MaxLaneCount|EDIDChanged|TransportDescription)"'
  }
}

# PD 端口健康计数器 (PortControllerInfo 按序展开, diff 用)
sample_pd() {
  ioreg -rw0 -c AppleSmartBattery -l 2>/dev/null | tr ',' '\n' | \
    grep -oE '"PortController(Attach|Detach|HardReset|ShortDetect|I2cErr|VdoFail|DataRoleSwap|PwrRoleSwap|DataRoleSwapFail|PwrRoleSwapFail|InpFetEnFail)Count"=[0-9]+'
}

# USB 拓扑全树 hash (设备重枚举会改变 registry id, hash 必变; 剔除易变的 busy/retain 计数防误报)
sample_usb_hash() {
  ioreg -p IOUSB -w0 2>/dev/null | \
    sed -E 's/, busy [0-9]+ \([0-9]+ ms\)//g; s/, retain [0-9]+//g' | md5 -q
}

sample_ws_cpu() {
  ps -o %cpu= -p "$(pgrep -x WindowServer 2>/dev/null)" 2>/dev/null | tr -d ' '
}

# 供电通道 (2026-10-27 新增)：数据/DP 通道全不变、只有电断掉的那类事件，旧三通道看不到
#   provider = pmset 报告的电源来源 (AC Power / Battery Power)
#   external = 是否接了外接电源；watts = 当前适配器瓦数
sample_power() {
  local prov
  prov="$(pmset -g batt 2>/dev/null | head -1 | sed -E "s/^Now drawing from '([^']*)'.*/\1/")"
  printf 'provider=%s\n' "${prov:-unknown}"
}

# 只在「电源来源变化」时调用（ioreg 全量 blob 约 7MB / 0.3s，不能每拍跑）
power_detail() {
  local bat ext watts
  bat="$(ioreg -l -w0 -c AppleSmartBattery 2>/dev/null)"
  ext="$(printf '%s\n' "$bat" | grep -oE '"ExternalConnected" = (Yes|No)' | head -1 | awk '{print $3}')"
  watts="$(printf '%s\n' "$bat" | grep -o '"Watts"=[0-9]*' | head -1 | cut -d= -f2)"
  printf 'external=%s watts=%s\n' "${ext:-unknown}" "${watts:-0}"
}

# 合盖状态 (2026-10-27 新增)：合盖 + 掉电 = macOS 判 clamshell sleep，屏幕会被系统关掉
sample_lid() {
  ioreg -r -k AppleClamshellState -d 4 2>/dev/null | \
    grep -oE '"AppleClamshellState" = (Yes|No)' | head -1 | awk '{print $3}'
}

# ---------- 事件记录与深快照 ----------

# 比较两轮 PD 计数器, 输出形如 "DetachCount 27->28" 的增量行
pd_diff() {
  local old="$1" new="$2"
  paste <(printf '%s\n' "$old") <(printf '%s\n' "$new") 2>/dev/null | \
  while IFS=$'\t' read -r o n; do
    local ok="${o%%=*}" ov="${o##*=}" nk="${n%%=*}" nv="${n##*=}"
    if [ "$ok" = "$nk" ] && [ "$ov" != "$nv" ]; then
      echo "  PD delta: ${ok#\"} ${ov} -> ${nv}"
    elif [ "$ok" != "$nk" ]; then
      echo "  PD layout changed (entry count/order differs)"
    fi
  done
}

take_snapshot() {
  local tag="$1"
  local dir
  dir="$SNAP_DIR/$(date '+%Y%m%d-%H%M%S').$(now_ms | cut -d. -f2)-$tag"
  mkdir -p "$dir"
  (
    ioreg -rw0 -c IOPortTransportStateDisplayPort -l   > "$dir/dp_ioreg.txt" 2>&1
    ioreg -rw0 -c AppleSmartBattery -l                 > "$dir/battery_portinfo.txt" 2>&1
    ioreg -p IOUSB -lw0                                > "$dir/usb_tree.txt" 2>&1
    system_profiler SPUSBDataType                      > "$dir/sysprofiler_usb.txt" 2>&1
    system_profiler SPDisplaysDataType                 > "$dir/sysprofiler_displays.txt" 2>&1
    system_profiler SPThunderboltDataType              > "$dir/sysprofiler_thunderbolt.txt" 2>&1
    ps -Aceo pid,pcpu,pmem,comm -r | head -25          > "$dir/top_cpu.txt" 2>&1
    pmset -g log 2>/dev/null | tail -50                > "$dir/pmset_log.txt" 2>&1
    pmset -g ps 2>/dev/null                             > "$dir/pmset_state.txt" 2>&1
    printf 'lid=%s\n' "$(sample_lid)"                  > "$dir/lid_state.txt" 2>&1
    sample_power                                        > "$dir/power_state.txt" 2>&1
    log show --last 10m --info --style compact \
      --predicate 'process == "kernel" OR process == "WindowServer" OR process == "powerd" OR subsystem CONTAINS[c] "thunderbolt"' 2>/dev/null \
      | tail -8000                                     > "$dir/syslog_10m.txt"
    # 恢复态对照: 5 秒后再采一轮快速通道
    sleep 5
    {
      echo "=== $(ts) post-event quick sample ==="
      echo "--- DP ---";  sample_dp
      echo "--- PD ---";  sample_pd
      echo "--- USB hash ---"; sample_usb_hash
      echo "--- WindowServer CPU ---"; sample_ws_cpu
    } > "$dir/post_quick.txt" 2>&1
  ) >/dev/null 2>&1 &
  disown 2>/dev/null || true
  echo "$dir"
}

prune_snapshots() {
  ls -1dt "$SNAP_DIR"/*/ 2>/dev/null | tail -n +$((SNAP_KEEP + 1)) | while IFS= read -r d; do
    rm -rf "$d"
  done
}

log_event() {
  echo "$(ts).$(now_ms | cut -d. -f2) $*" >> "$EVENTS_LOG"
}

# ---------- 子命令 ----------

cmd_once() {
  echo "=== display_monitor once @ $(ts) ==="
  echo
  echo "--- DP 链路节点 (IOPortTransportStateDisplayPort) ---"
  sample_dp
  echo
  echo "--- PD 端口健康计数器 (PortControllerInfo, 按端口顺序展开) ---"
  sample_pd
  echo
  echo "--- USB 拓扑 ---"
  ioreg -p IOUSB -w0 2>/dev/null | grep -E '\+\-o' 
  echo "(tree hash: $(sample_usb_hash))"
  echo
  echo "--- WindowServer CPU ---"
  sample_ws_cpu
  echo
  echo "--- 供电 / 合盖（2026-10-27 新增通道）---"
  sample_power
  printf 'lid=%s\n' "$(sample_lid)"
  echo
  echo "--- 当前显示器 ---"
  system_profiler SPDisplaysDataType 2>/dev/null | grep -E '^\s+\S.*:$|Resolution|Connection Type' | head -12
}

cmd_status() {
  local pid
  pid="$(pgrep -f 'display_monitor.sh run' | head -1)"
  if [ -n "$pid" ]; then
    echo "monitor: RUNNING (pid $pid)"
  else
    echo "monitor: NOT RUNNING"
    echo "  安装: $0 install   (launchd 常驻)"
    echo "  临时: $0 run       (前台运行)"
  fi
  echo "log dir: $LOG_DIR"
  echo
  if [ -f "$HEARTBEAT_LOG" ]; then
    echo "--- 最近 heartbeat ---"
    tail -3 "$HEARTBEAT_LOG"
    echo
  fi
  local ev_count=0
  [ -f "$EVENTS_LOG" ] && ev_count="$(grep -c ' EVENT ' "$EVENTS_LOG" 2>/dev/null)" || true
  echo "--- 最近事件 (${ev_count:-0} 条总计) ---"
  [ -f "$EVENTS_LOG" ] && grep ' EVENT ' "$EVENTS_LOG" | tail -10
  echo
  echo "--- 快照目录 (最近 5 个) ---"
  ls -1dt "$SNAP_DIR"/*/ 2>/dev/null | head -5
  echo "共 $(ls -1d "$SNAP_DIR"/*/ 2>/dev/null | wc -l | tr -d ' ') 个快照"
}

cmd_run() {
  # 防重复实例：用 pid 锁文件，不再靠 pgrep -f 匹配命令行
  # （2026-10-27：pgrep -f 会匹配到自己的子 shell / pgrep 自身 / 调用者的 bash -c 命令行，
  #   导致每次重启都误判「已有实例在运行」而退出，launchd 反复重启也起不来。）
  local lock="$LOG_DIR/.run.lock" oldpid
  if ! mkdir "$lock" 2>/dev/null; then
    oldpid="$(cat "$lock/pid" 2>/dev/null)"
    if [ -n "${oldpid:-}" ] && kill -0 "$oldpid" 2>/dev/null; then
      echo "$(ts) another instance already running (pid $oldpid), exiting" >> "$EVENTS_LOG"
      exit 1
    fi
    rm -rf "$lock"
    mkdir "$lock" 2>/dev/null || { echo "$(ts) cannot create lock $lock, exiting" >> "$EVENTS_LOG"; exit 1; }
  fi
  echo $$ > "$lock/pid"
  # TERM/INT 必须真的退出：只挂 EXIT 清锁、另用 handler 显式 exit，
  # 否则 bash 执行完 trap 会继续跑（2026-10-27 另一个 session 指出：
  # kickstart 后旧进程残留、锁又被删掉 → 可能出现两个实例同时写日志）。
  trap 'rm -rf "$lock"' EXIT
  trap 'exit 0' INT TERM

  log_event "MONITOR START pid=$$"
  local prev_dp prev_pd prev_usb prev_power prev_lid last_snap=0 tick=0
  prev_dp="$(sample_dp)"; prev_pd="$(sample_pd)"; prev_usb="$(sample_usb_hash)"
  prev_power="$(sample_power)"; prev_lid="$(sample_lid)"
  log_event "BASELINE pd_counters=[$(printf '%s\n' "$prev_pd" | tr '\n' ' ')] usb_hash=$prev_usb power=[$(printf '%s' "$prev_power" | tr '\n' ' ')] lid=${prev_lid:-unknown}"

  while true; do
    local cur_dp cur_pd cur_usb cur_power cur_lid ws changes=""
    cur_dp="$(sample_dp)"; cur_usb="$(sample_usb_hash)"
    cur_pd="$(sample_pd)"; cur_power="$(sample_power)"
    # 合盖状态变化慢，每 10 拍采一次，省开销
    if [ $((tick % 10)) -eq 0 ]; then cur_lid="$(sample_lid)"; else cur_lid="$prev_lid"; fi

    [ "$cur_dp"    != "$prev_dp"    ] && changes="${changes}dp,"
    [ "$cur_pd"    != "$prev_pd"    ] && changes="${changes}pd,"
    [ "$cur_usb"   != "$prev_usb"   ] && changes="${changes}usb,"
    [ "$cur_power" != "$prev_power" ] && changes="${changes}power,"
    [ "$cur_lid"   != "$prev_lid"   ] && changes="${changes}lid,"

    if [ -n "$changes" ]; then
      ws="$(sample_ws_cpu)"
      changes="${changes%,}"
      log_event "EVENT changes=[$changes] ws_cpu=$ws"
      if [ "$cur_pd" != "$prev_pd" ]; then
        pd_diff "$prev_pd" "$cur_pd" >> "$EVENTS_LOG"
      fi
      if [ "$cur_usb" != "$prev_usb" ]; then
        echo "  USB tree changed: $prev_usb -> $cur_usb" >> "$EVENTS_LOG"
      fi
      if [ "$cur_power" != "$prev_power" ]; then
        echo "  power: $(printf '%s' "$prev_power" | tr '\n' ' ') -> $(printf '%s' "$cur_power" | tr '\n' ' ') [$(power_detail | tr '\n' ' ')]" >> "$EVENTS_LOG"
      fi
      if [ "$cur_lid" != "$prev_lid" ]; then
        echo "  lid: ${prev_lid:-unknown} -> ${cur_lid:-unknown}" >> "$EVENTS_LOG"
      fi
      local t now
      now="$(now_s)"
      if [ $((now - last_snap)) -ge $SNAP_THROTTLE_SEC ]; then
        last_snap=$now
        t="$(take_snapshot event)"
        log_event "SNAPSHOT $t"
        prune_snapshots
      else
        log_event "SNAPSHOT throttled (storm in progress)"
      fi
    fi

    prev_dp="$cur_dp"; prev_pd="$cur_pd"; prev_usb="$cur_usb"
    prev_power="$cur_power"; prev_lid="$cur_lid"

    tick=$((tick + 1))
    if [ $((tick % HEARTBEAT_EVERY)) -eq 0 ]; then
      local dp_active dp_nodes
      dp_active="$(printf '%s\n' "$cur_dp" | grep -c '"Active" = Yes')"
      dp_nodes="$(printf '%s\n' "$cur_dp" | grep -c 'id 0x')"
      echo "$(ts) HB dp_nodes=$dp_nodes dp_active=$dp_active ws_cpu=$(sample_ws_cpu) usb=$cur_usb pd=[$(printf '%s\n' "$cur_pd" | grep -oE '(Attach|Detach|HardReset)Count"=[0-9]+' | tr '\n' ' ')] power=[$(printf '%s' "$cur_power" | tr '\n' ' ')] lid=${cur_lid:-unknown}" >> "$HEARTBEAT_LOG"
    fi

    sleep "$POLL_INTERVAL"
  done
}

cmd_install() {
  local script_path plist_dest
  script_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  plist_dest="$HOME/Library/LaunchAgents/${LABEL}.plist"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$plist_dest" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${script_path}</string>
    <string>run</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${LOG_DIR}/stdout.log</string>
  <key>StandardErrorPath</key><string>${LOG_DIR}/stderr.log</string>
</dict>
</plist>
EOF
  launchctl unload "$plist_dest" 2>/dev/null
  launchctl load -w "$plist_dest"
  echo "installed: $plist_dest"
  echo "monitor should now be running; verify with: $0 status"
}

cmd_uninstall() {
  local plist_dest="$HOME/Library/LaunchAgents/${LABEL}.plist"
  launchctl unload "$plist_dest" 2>/dev/null
  rm -f "$plist_dest"
  echo "uninstalled. logs kept at $LOG_DIR"
}

case "${1:-}" in
  run)       cmd_run ;;
  once)      cmd_once ;;
  status)    cmd_status ;;
  install)   cmd_install ;;
  uninstall) cmd_uninstall ;;
  *)
    sed -n '2,30p' "$0"
    ;;
esac
