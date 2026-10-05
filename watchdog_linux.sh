#!/usr/bin/env bash

# this script is to run from linux.wpi.edu to watch the VM
# running the cron every minute and fix when VM goes wrong
# the workflow:
# 1) protect
#     running the check to see if VM reachable
#     if reachable then running protect_vm.sh --check
#     if not locked down then run protect_vm.sh
#     if locked down then all good
# 2) check app
#     check the app port
#     if not work deploy the app running deploy_app.sh
# 3) send alert via Discord

set -uo pipefail

# declare config
export PORT="${PORT:-22019}"
export MACHINE="${MACHINE:-paffenroth-23.dyn.wpi.edu}"
export VM_USER="${VM_USER:-student-admin}"
export OUR_KEY="${OUR_KEY:-$HOME/.ssh/cs553}"
APP_PORTS="${APP_PORTS:-7860}"
DEPLOY_GRACE="${DEPLOY_GRACE:-900}"
DEPLOY_TIMEOUT="${DEPLOY_TIMEOUT:-1800}"
STATE_DIR="${STATE_DIR:-$HOME/.cs553_watchdog}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE="linux"

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

vm() {
  ssh -F /dev/null -i "$OUR_KEY" -p "$PORT" \
    -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 \
    -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    "$VM_USER@$MACHINE" "$@"
}

# check VM
"$SCRIPT_DIR/protect_vm.sh" --check
case $? in
  0) ;;
  4)
    set_status relocking "VM is not locked down; locking it down now"
    if ! "$SCRIPT_DIR/protect_vm.sh"; then
      set_status lockdown_failed "lockdown failed; check the watchdog log"
      exit 1
    fi
    notify "lockdown done: only our keys get in again"
    ;;
  3) 
    set_status takeover "can't log in with any key: someone takes over"
    exit 1
    ;;
  2)
    if port_open 130.215.41.1 53 || port_open 1.1.1.1 443; then
        set_status down "VM is down - linux machine still works"
    else 
        set_status disconnect "linux machine disconnects to network"
    fi
    exit 1
    ;;
  *) set_status error "protect_vm.sh --check failed; check the watchdog log"; exit 1 ;;
esac

# check the app if it still deployed
if command -v flock >/dev/null; then
  exec 9>"$STATE_DIR/lock"
  flock -n 9 || { log "previous run is still deploying; skipping the app check"; exit 0; }
fi

# check if the port works
down=""
for p in $APP_PORTS; do
  vm "curl -sf -o /dev/null --max-time 10 http://localhost:$p/" </dev/null
  case $? in
    0) ;;
    255) log "lost the SSH connection during the app check; trying again next run"; exit 1 ;;
    *) down="$down $p" ;;
  esac
done

if [ -z "$down" ]; then
  set_status ok "all good: locked down, app port(s) $APP_PORTS up"
  exit 0
fi

# checking before redeploy if the last deploy still work
now=$(date +%s)
last=$(cat "$STATE_DIR/last_deploy" 2>/dev/null || echo 0)
if [ $((now - last)) -lt "$DEPLOY_GRACE" ]; then
  log "app port(s)$down not up yet, but the last deploy was only $((now - last))s ago; waiting"
  exit 0
fi

# check if app down and no deploy file
if [ ! -x "$SCRIPT_DIR/deploy_app.sh" ]; then
  set_status app_down "app down on port(s)$down, and there is no deploy_app.sh to fix it"
  exit 1
fi

# deploy app
set_status deploying "app down on port(s)$down; redeploying"
echo "$now" > "$STATE_DIR/last_deploy"
deploy=("$SCRIPT_DIR/deploy_app.sh")
if command -v timeout >/dev/null; then deploy=(timeout "$DEPLOY_TIMEOUT" "${deploy[@]}"); fi
if ! "${deploy[@]}" 9>&-; then
  set_status deploy_failed "deploy_app.sh failed; check the watchdog log"
  exit 1
fi
log "deploy finished; next run will check whether the app came up"