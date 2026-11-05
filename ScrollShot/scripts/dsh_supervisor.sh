#!/bin/bash
# DSH 常驻守护（supervisor）—— 2026-10-26 建立
#
# 目的：让这台 Mac 上的 DSH「时刻在线」——
#   1) 开机/登录自动起来（由 LaunchAgent com.scrollshot.dsh-supervisor 的 RunAtLoad 拉起）
#   2) dsh 进程崩溃/被杀后自动重启（脚本自身由 launchd KeepAlive 保活）
#   3) 启动前确保 Tailscale 在跑、serve 规则（固定名字 → 127.0.0.1:3080）存在
#   4) **只在 3080 空闲时才启动 dsh**：不会抢已经在跑的实例，因此可以「随时安装、不打断当前会话」，
#      等现有 dsh 自己退出后由本脚本接管（或下次重启由本脚本直接启动）
#
# 地址策略（与 skills/dsh-start-stable.sh 一致，勿改）：
#   dsh 永远绑回环 127.0.0.1:3080；对外只认 tailnet 固定名字。
#   本机：http://127.0.0.1:3080
#   外部：http://tonys-macbook-air-2-2.taild8c441.ts.net:3080
#
# 日志：~/Library/Logs/dsh-supervisor.log
# 最近一次启动的带 token 链接：~/.dsh/last-start-url.txt
#
# 自测（不会碰真 DSH、不改 serve 规则）：
#   DSH_PORT=3999 DSH_TEST_CMD='/bin/sleep 30' DSH_SKIP_SERVE=1 DSH_SKIP_TS=1 \
#     bash scripts/dsh_supervisor.sh
#
# 注意：macOS 自带 bash 3.2，$VAR 后面紧跟中文标点会被并进变量名 → 本文件变量一律写 ${VAR}。

set -uo pipefail

NAME="tonys-macbook-air-2-2.taild8c441.ts.net"
TS="/usr/local/bin/tailscale"
PORT="${DSH_PORT:-3080}"
LOG="${DSH_LOG:-$HOME/Library/Logs/dsh-supervisor.log}"
URL_FILE="${DSH_URL_FILE:-$HOME/.dsh/last-start-url.txt}"
RESTART_DELAY="${DSH_RESTART_DELAY:-3}"

mkdir -p "$(dirname "${LOG}")" 2>/dev/null || true
mkdir -p "$(dirname "${URL_FILE}")" 2>/dev/null || true

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"${LOG}"; }

# 日志超过 5MB 就轮转一次，避免长年累月把磁盘吃掉
rotate_log() {
  local size
  size=$(wc -c <"${LOG}" 2>/dev/null | tr -d ' ')
  [ -n "${size}" ] || return 0
  if [ "${size}" -gt 5242880 ]; then
    mv -f "${LOG}" "${LOG}.1" 2>/dev/null || true
    log "日志超过 5MB，已轮转为 ${LOG}.1"
  fi
}

# 找 dsh 可执行文件：npx 缓存路径带哈希会变，所以每次启动都重新解析
resolve_dsh() {
  local p
  for p in "${HOME}"/.npm-global/cache/_npx/*/node_modules/.bin/dsh; do
    [ -x "${p}" ] && { printf '%s\n' "${p}"; return 0; }
  done
  command -v dsh 2>/dev/null && return 0
  return 1
}

port_busy() { lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN -t >/dev/null 2>&1; }

ensure_tailscale() {
  [ -n "${DSH_SKIP_TS:-}" ] && return 0
  if ! "${TS}" status --json 2>/dev/null | grep -q '"BackendState": "Running"'; then
    log "tailscale 未运行 → open -a Tailscale"
    open -a Tailscale 2>/dev/null || true
    local i
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      "${TS}" status --json 2>/dev/null | grep -q '"BackendState": "Running"' && break
      sleep 1
    done
  fi
  if ! "${TS}" status --json 2>/dev/null | grep -q '"BackendState": "Running"'; then
    log "⚠️ tailscale 20s 内没进入 Running（dsh 仍会启动，但外部暂时访问不到）"
    return 0
  fi
  # serve 规则：固定名字 → 127.0.0.1:PORT（--bg 持久化，重启后一般在；不在就补）
  if ! "${TS}" serve status 2>/dev/null | grep -q "proxy http://127.0.0.1:${PORT}"; then
    log "serve 规则缺失 → 重建"
    "${TS}" serve --bg "--http=${PORT}" "${PORT}" </dev/null >/dev/null 2>&1 || \
      log "⚠️ 重建 serve 失败（稍后重试）"
  fi
}

start_dsh() {
  local child
  if [ -n "${DSH_TEST_CMD:-}" ]; then
    log "自测模式：执行 ${DSH_TEST_CMD}"
    eval "${DSH_TEST_CMD}" >>"${LOG}" 2>&1 &
    child=$!
  else
    local bin="${DSH_BIN:-}"
    if [ -z "${bin}" ]; then
      bin="$(resolve_dsh || true)"
      # npx 缓存被清掉时不要每 3 秒刷日志，退避 30s 再试
      [ -n "${bin}" ] || { log "✗ 找不到 dsh 可执行文件，30s 后重试"; sleep 30; return 1; }
    fi
    # 记录启动前的行数：只从新追加的日志里找 token，避免捡到上一次启动的旧 token
    local before from
    before=$(wc -l <"${LOG}" 2>/dev/null | tr -d ' ')
    [ -n "${before}" ] || before=0
    from=$((before + 1))
    log "启动 dsh：${bin} web --host 127.0.0.1 --port ${PORT}"
    "${bin}" web --host 127.0.0.1 --port "${PORT}" --no-open \
      --trusted-host "${NAME}" >>"${LOG}" 2>&1 &
    child=$!
    # 等启动日志里的 token 链接，写一份到固定文件，方便重启后取用
    local i
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
      tail -n +"${from}" "${LOG}" 2>/dev/null | grep -q 'dsh web: http' && break
      kill -0 "${child}" 2>/dev/null || break
      sleep 1
    done
    local url
    url=$(tail -n +"${from}" "${LOG}" 2>/dev/null | \
      grep -o "http://127.0.0.1:${PORT}/?token=[A-Za-z0-9_-]*" | tail -1)
    [ -n "${url}" ] && printf '%s\n' "${url}" >"${URL_FILE}"
  fi
  CHILD_PID="${child}"
  return 0
}

CHILD_PID=""
# launchd 停我们时不要留下孤儿 dsh（否则下一个实例只能干等端口释放）
cleanup() {
  [ -n "${CHILD_PID}" ] && kill "${CHILD_PID}" 2>/dev/null
  exit 0
}
trap cleanup INT TERM

log "=== supervisor 启动 (pid $$, port ${PORT}) ==="

tick=0
while true; do
  # Tailscale / serve 规则 / 日志轮转：每 ~60s 校正一次（即使 dsh 早已在跑，serve 规则被清掉也能自动补回）
  if [ $((tick % 6)) -eq 0 ]; then
    rotate_log
    ensure_tailscale
  fi
  tick=$((tick + 1))

  # 3080 已被别人占着（例如手动启动的实例）→ 不抢，等它退出
  if port_busy; then
    sleep 10
    continue
  fi

  start_dsh
  if [ -z "${CHILD_PID}" ]; then
    sleep 30
    continue
  fi

  # dsh 运行期间也要巡检：serve 规则被删、Tailscale 掉线，在这里补回来。
  # （原来是 wait "${child}" 阻塞到 dsh 退出，运行期完全不自愈——2026-10-27 另一个 session 指出。）
  while kill -0 "${CHILD_PID}" 2>/dev/null; do
    tick=$((tick + 1))
    if [ $((tick % 6)) -eq 0 ]; then
      rotate_log
      ensure_tailscale
    fi
    sleep 5
  done
  wait "${CHILD_PID}" 2>/dev/null
  CHILD_PID=""
  log "dsh 已退出（可能崩溃/被杀）→ ${RESTART_DELAY}s 后重启"
  sleep "${RESTART_DELAY}"
done
