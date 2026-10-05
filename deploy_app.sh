#!/usr/bin/env bash

# this script is to deploy the app to the VM
# it runs from the linux.wpi.edu or our laptop (if needed), never on the VM
# watchdog_linux.sh will call it when the app port 7860 is down
# Workflow
# 1) check locking down the VM
# 2) copy our HF token from .env to the VM
# 3) on the VM: install uv, clone or update the repo, install dependencies
#    on the VM: install a systemd service that runs the app and restart it on crash
#    on the VM: wait until the app answers on its port
# Usage
# ./deploy_app.sh
# Exit codes:
# 0 deployed
# 1 error

# add bash error gatekeeper
set -euo pipefail

# declare config
PORT="${PORT:-22019}"
MACHINE="${MACHINE:-paffenroth-23.dyn.wpi.edu}"
VM_USER="${VM_USER:-student-admin}"
OUR_KEY="${OUR_KEY:-$HOME/.ssh/cs553}"
REPO_URL="${REPO_URL:-https://github.com/twindinx/cs553cs02.git}"
BRANCH="${BRANCH:-main}"
APP_PORT="${APP_PORT:-7860}"        # Gradio port inside the VM
PUBLIC_PORT="${PUBLIC_PORT:-8019}"  # 8000 + group number, forwarded to APP_PORT
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"

# define log function to print the command execution
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# terminate script with error message
die() { log "ERROR: $1" >&2; exit 1; }

# run a command on the VM with our key
vm () {
    ssh -F /dev/null -i "$OUR_KEY" -p "$PORT" \
    -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 \
    -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    "$VM_USER@$MACHINE" "$@"
}

# get the env value from .env
env_value() {
    [ -f "$ENV_FILE" ] || return 0
    grep -E "^[[:space:]]*$1=" "$ENV_FILE" | tail -1 \
    | sed -E "s/^[[:space:]]*$1=//" | tr -d '\r' \
    | sed -E "s/^[\"']//; s/[\"']\$//"
} 

# check to make sure only our team keys can log in
log "1/3 locking down the VM"
"$SCRIPT_DIR/protect_vm.sh" || die "protect_vm.sh failed"

# copy the HF token through stdin so it never shows up in the command line
log "2/3 copying the HF token"
hf_token="$(env_value HF_TOKEN)"
if [ -n "$hf_token" ]; then
    printf '%s' "$hf_token" \
    | vm 'mkdir -p ~/.cache/huggingface && umask 077 && cat > ~/.cache/huggingface/token' \
    || die "couldn't copy the HF token"
else
    log "no HF_TOKEN in $ENV_FILE: the app will only use the local model"
fi

# send the script to VM and run it there with bash
log "3/3 installing and starting the app on the VM."
vm "bash -s -- '$REPO_URL' '$BRANCH' '$APP_PORT'" << 'REMOTE' || die "Setup on the VM failed"
# wrap everything in a function for bash to read the whole function before running it
main() {
    set -euo pipefail
    local repo_url="$1" branch="$2" app_port="$3"
    local app_dir="$HOME/photo-critic" service="photo-critic"

    # uv manage python and packages
    # install python by itself
    export PATH="$HOME/.local/bin:$PATH"
    if ! command -v uv >/dev/null; then
        echo "installing uv"
        curl -LsSf https://astral.sh/uv/install.sh | sh
    fi

    # check git repo and update the code in VM
    if [ -d "$app_dir/.git" ]; then
        echo "updating $app_dir"
        git -C "$app_dir" fetch --quiet origin "$branch"
        git -C "$app_dir" reset --quiet --hard "origin/$branch"
    else
        echo "cloning $repo_url"
        git clone --quiet --branch "$branch" "$repo_url" "$app_dir"
    fi

    # install the versions following uv.lock
    cd "$app_dir"
    uv sync --locked --no-dev

    # systemd starts the app at boot and restart it 5s after any crash
    sudo tee "/etc/systemd/system/$service.service" >/dev/null <<EOF
[Unit]
Description=Photo Critic
After=network-online.target
Wants=network-online.target

[Service]
User=$(whoami)
WorkingDirectory=$app_dir
Environment=GRADIO_SERVER_NAME=0.0.0.0
Environment=GRADIO_SERVER_PORT=$app_port
Environment=PYTHONUNBUFFERED=1
ExecStart=$app_dir/.venv/bin/python main.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable --quiet "$service"
    sudo systemctl restart "$service"

    # downloads the local model
    echo "waiting for the app on port $app_port"
    for i in $(seq 1 120); do
        if curl -sf -o /dev/null --max-time 5 "http://localhost:$app_port/"; then
            echo "app is up after about $((i * 5))s"
            return 0
        fi
        sleep 5
    done
    echo "the app did not answer within 10 minutes, last log lines:" >&2
    sudo journalctl -u "$service" -n 30 --no-pager >&2
    return 1
}
main "$@"
REMOTE

log "deployed: http://$MACHINE:$PUBLIC_PORT"
