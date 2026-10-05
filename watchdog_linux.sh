#!/usr/bin/env bash

# this script is to run from linux.wpi.edu to watch the VM
# running the cron every 5 minute and fix when VM goes wrong
# the workflow:
# 1) protect
#     use our key(s) to get in and check the app port
#     if our key(s) rejected (VM reset) or key changed, run protect_vm.sh
#     if VM does not answer, check "VM down" or "linux machine offline"
# 2) if the app is down, deploy the app with deploy_app.sh
# 3) send alert via Discord

set -uo pipefail
# add nullglob to prevent error with team_keys
shopt -s nullglob

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
TEAM_KEYS_DIR="${TEAM_KEYS_DIR:-$SCRIPT_DIR/team_keys}"
NET_CHECK_URL="${NET_CHECK_URL:-https://github.com}"
PROTECT_RETRY="${PROTECT_RETRY:-600}"
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

# run protect_vm.sh to lock down again
# if it failed, wait PROTECT_RETRY (10min) before the next try
relock() {
  local now last
  now=$(date +%s)
  last=$(cat "$STATE_DIR/last_lockdown_fail" 2>/dev/null || echo 0)
  if [ $((now - last)) -lt "$PROTECT_RETRY" ]; then
    log "$1, but the last lockdown failed $((now - last))s ago; trying again after ${PROTECT_RETRY}s"
    return 1
  fi
  set_status relocking "$1; running protect_vm.sh"
  if ! "$SCRIPT_DIR/protect_vm.sh"; then
    echo "$now" > "$STATE_DIR/last_lockdown_fail"
    set_status lockdown_failed "lockdown failed; check the watchdog log"
    return 1
  fi
  rm -f "$STATE_DIR/last_lockdown_fail"
  notify "lockdown done: only our keys get in again"
}

# make sure there is 1 run at a time and cron does not start another
if command -v flock >/dev/null; then
  exec 9>"$STATE_DIR/lock"
  flock -n 9 || { log "previous run is still running (deploying?); skipping this run"; exit 0; }
fi

# get our key(s)
want=$(awk 'NF && $1 !~ /^#/ && !seen[$2]++' "$OUR_KEY.pub" "$TEAM_KEYS_DIR"/*.pub)
want_sum=$(printf '%s\n' "$want" | sha256sum | cut -d' ' -f1)

# check VM, keys and port
err_file="$STATE_DIR/ssh.err"
result=$(vm "bash -s -- $APP_PORTS" 2>"$err_file" <<'REMOTE'
echo "keys=$(sha256sum < ~/.ssh/authorized_keys 2>/dev/null | cut -d' ' -f1)"
for p in "$@"; do
  if curl -sf -o /dev/null --max-time 10 "http://localhost:$p/"; then
    echo "app_$p=up"
  else
    echo "app_$p=down"
  fi
done
REMOTE
)
code=$?

if [ "$code" -ne 0 ]; then
  if grep -q "Permission denied" "$err_file"; then
    # our key no longer works: the VM may be reset
    relock "our key is rejected (VM reset?)" || exit 1
    exit 0  # the next run checks the app with our key
  fi
  # no answer at all: check if VM down or linux machine offline
  log "ssh failed (exit $code): $(tr '\n' ' ' < "$err_file")"
  if curl -s -o /dev/null -m 10 "$NET_CHECK_URL"; then
    set_status down "VM unreachable - linux machine still works"
  else
    set_status disconnect "linux machine lost its network; can't check the VM"
  fi
  exit 1
fi

# check if keys changed but our keys still work (someone adds in for example)
if ! grep -qx "keys=$want_sum" <<< "$result"; then
  relock "authorized_keys changed on the VM" || exit 1
fi


# check if the app port works
down=""
for p in $APP_PORTS; do
  grep -qx "app_$p=up" <<< "$result" || down="$down $p"
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