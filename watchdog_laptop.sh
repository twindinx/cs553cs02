#!/usr/bin/env bash

# this script is to run from laptop to watch the VM
# running the launchd every few minutes and fix protection when VM goes wrong
# the workflow:
# 1) protect
#     running the check to see if VM reachable
#     if reachable then running protect_vm.sh --check
#     if not locked down then run protect_vm.sh
#     if locked down then all good
# 2) send alert via Discord

set -uo pipefail

# declare config
export PORT="${PORT:-22019}"
export MACHINE="${MACHINE:-paffenroth-23.dyn.wpi.edu}"
export VM_USER="${VM_USER:-student-admin}"
export OUR_KEY="${OUR_KEY:-$HOME/.ssh/cs553}"
STATE_DIR="${STATE_DIR:-$HOME/.cs553_watchdog}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE="laptop"

mkdir -p "$STATE_DIR"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# declare webhook
WEBHOOK_VAR="${WEBHOOK_VAR:-DISCORD_WEBHOOK_VM}"
get_webhook() {
  local env="${ENV_FILE:-$SCRIPT_DIR/.env}" url=""
  if [ -f "$env" ]; then
    url=$(grep -E "^[[:space:]]*$WEBHOOK_VAR=" "$env" | tail -1 \
          | sed -E "s/^[[:space:]]*$WEBHOOK_VAR=//" | tr -d '\r' \
          | sed -E "s/^[\"']//; s/[\"']\$//")
  fi
  [ -z "$url" ] && [ -f "$STATE_DIR/discord_webhook" ] && url=$(cat "$STATE_DIR/discord_webhook")
  printf '%s' "$url"
}

# define function to check port
port_open() {
  perl -MIO::Socket::INET -e \
    'exit(IO::Socket::INET->new(PeerAddr=>$ARGV[0], PeerPort=>$ARGV[1], Timeout=>5) ? 0 : 1)' \
    "$1" "$2" 2>/dev/null
}

# notify function
notify() {
    log "$1"
    local hook
    hook=$(get_webhook)
    [ -n "$hook" ] || return 0
    curl -sf -m 10 -H 'Content-Type: application/json' \
    -d "{\"content\": \"[$SOURCE TO VM:$PORT] $1\"}" "$hook" >/dev/null || log "(Discord alert failed)"
}

# record the status and alert if it changes since last run
set_status() {
    local old
    old=$(cat "$STATE_DIR/status" 2>/dev/null)
    echo "$1" > "$STATE_DIR/status"
    if [ "$1" = "$old" ]; then log "$2"; else notify "$2"; fi
}

# check VM
"$SCRIPT_DIR/protect_vm.sh" --check
case $? in
  0) set_status ok "locked down - only our keys get in";;
  4)
    set_status relocking "VM is not locked down; locking it down now"
    if ! "$SCRIPT_DIR/protect_vm.sh"; then
      set_status lockdown_failed "lockdown failed; check the watchdog log"
      exit 1
    fi
    notify "relock done: only our keys get in again"
    ;;
  3) 
    set_status takeover "can't log in with any key: someone takes over"
    exit 1
    ;;
  2)
    if port_open linux.wpi.edu 22; then
        set_status down "VM unreachable but WPI network is reachable"
    else 
        set_status offvpn "VPN off"
    fi
    exit 1
    ;;
  *) set_status error "protect_vm.sh --check failed; check the watchdog log"; exit 1 ;;
esac