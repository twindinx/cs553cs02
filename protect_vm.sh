#!/usr/bin/env bash

# this script is to make sure our VM is protected when professor resets VMs
# it ensures our key ($OUR_KEY.pub) and every *.pub key in team_keys/ get access to VM
# Usage:
#   ./protect_vm.sh          lock the VM (or confirm it's locked)
#   ./protect_vm.sh --check  only report which keys can log in
# Exit codes:
# 0  locked down - our key works, student-admin key rejected
# 1  error
# 2  unreachable (VM down)
# 3  port reacheable but none key works
# 4  (--check only) not locked down - student-admin key works

# add bash error gatekeeper
set -euo pipefail
# add nullglob to prevent error with team_keys
shopt -s nullglob

# declare config
PORT="${PORT:-22019}"
MACHINE="${MACHINE:-paffenroth-23.dyn.wpi.edu}"
VM_USER="${VM_USER:-student-admin}"
OUR_KEY="${OUR_KEY:-$HOME/.ssh/cs553}"
ADMIN_KEY="${ADMIN_KEY:-$HOME/.ssh/student-admin_key}"
TEAM_KEYS_DIR="${TEAM_KEYS_DIR:-$(cd "$(dirname "$0")" && pwd)/team_keys}"

# define log fuction to print the date and time of command execution
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# terminate script with error message and exit code
die() { log "ERROR: $1" >&2; exit "${2:-1}"; }

# evaluates a condition passed as its argument
# print accepted if it succeeds or rejected if fail
state() { if $1; then echo accepted; else echo rejected; fi; }

# define function to check port
port_open() {
  perl -MIO::Socket::INET -e \
    'exit(IO::Socket::INET->new(PeerAddr=>$ARGV[0], PeerPort=>$ARGV[1], Timeout=>5) ? 0 : 1)' \
    "$1" "$2" 2>/dev/null
}

# define vm command saving 1st argument to the key variable and pass to command
vm() {
    local key=$1
    shift
    ssh -F /dev/null -i "$key" -p "$PORT" \
    -o IdentitiesOnly=yes  -o BatchMode=yes -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    "$VM_USER@$MACHINE" "$@"
}

# decalre the function to check login using a key
can_login() { vm "$1" true </dev/null >/dev/null 2>&1; }

# extract the blob of a public key from private key
# it must have no passphrase so cron can use it
key_blob() { ssh-keygen -y -P "" -f "$1" 2>/dev/null | awk '{print $2}'; }

# combined our key plus other team keys for the VM authorized_keys
desired_keys() { awk 'NF && $1 !~ /^#/ && !seen[$2]++' "$OUR_KEY.pub" "$TEAM_KEYS_DIR"/*.pub; }

# check the command argument
check_only=false
case "${1:-}" in
    --check) check_only=true ;;
    "") ;;
    *) die "usage: $0 [--check]" ;;
esac

# Check if the key exists to not brick the machine
for f in "$OUR_KEY" "$OUR_KEY.pub" "$ADMIN_KEY"; do
    [ -f "$f" ] || die "missing key file: $f"
done

our_blob=$(key_blob "$OUR_KEY") || die "can't read $OUR_KEY"
[ "$our_blob" = "$(awk '{print $2}' "$OUR_KEY.pub")" ] || die "$OUR_KEY.pub doesn't match $OUR_KEY"
admin_blob=$(key_blob "$ADMIN_KEY") || die "can't read $ADMIN_KEY"
want=$(desired_keys)
# check if student-admin key is in team_keys_dir to avoid leaking it back to VM
case "$want" in
  *"$admin_blob"*) die "the student-admin public key is in $TEAM_KEYS_DIR; remove it" ;;
esac

# Check if the VM is reachable
if ! port_open "$MACHINE" "$PORT"; then
    die "VM unreachable: port $PORT not answering (VM dowm, or we're off the WPI network)" 2
fi

# if port open
# check which keys the VM accepting
ours_ok=false
admin_ok=false
if can_login "$OUR_KEY"; then ours_ok=true; fi
if can_login "$ADMIN_KEY"; then admin_ok=true; fi
log "$VM_USER@$MACHINE:$PORT ; our key: $(state $ours_ok); student-admin key: $(state $admin_ok)"

# check VM status/keys and output exit codes
if ! $ours_ok && ! $admin_ok; then
    die "neither key gets in: someone takes over" 3
fi
if $check_only; then
  # Locked down = our key works and the student-admin key is refused
  if $ours_ok && ! $admin_ok; then
    log "locked down"
    exit 0
  fi
  # admin key still works = not locked down.
  log "NOT locked down"
  exit 4
fi

# if our key not in VM, login with admin key and add our keys
# then check if it works
if ! $ours_ok; then
    log "logging in with student-admin key and adding our team's keys"
    printf '%s\n' "$want" | vm "$ADMIN_KEY" '
        umask 077; mkdir -p "$HOME/.ssh"; f="$HOME/.ssh/authorized_keys"
        if [ -s "$f" ] && [ -n "$(tail -c1 "$f")" ]; then echo >> "$f"; fi
        cat >> "$f"' || die "couldn't add our keys to the VM"
    can_login "$OUR_KEY" || die "added our keys but ours still can't log in; student-admin key left in place"
fi

# log in with our key and create the new temp file with our team keys
# rename and move to place
# to ensure if connection drop it will not affect the current authorized_keys file
have=$(vm "$OUR_KEY" 'cat "$HOME/.ssh/authorized_keys" 2>/dev/null' </dev/null || true )
if [ "$have" = "$want" ] && ! $admin_ok; then
  log "already locked down; nothing to change"
  exit 0
fi
log "replacing authorized_keys with only our team's keys"
printf '%s\n' "$want" | vm "$OUR_KEY" '
  umask 077; d="$HOME/.ssh"
  cat > "$d/authorized_keys.new" && mv -f "$d/authorized_keys.new" "$d/authorized_keys"
  rm -f "$d/authorized_keys2"' || die "couldn't replace authorized_keys on the VM"

# final check if our keys accepted and student-admin key rejected
can_login "$OUR_KEY" || die "our key still cannot log in, please check manually"
if can_login "$ADMIN_KEY"; then
    die "the student-admin key still gets in, please check manually"
fi
log "locked down: $(printf '%s\n' "$want" | wc -l | tr -d ' ') team key(s) authorized, student-admin key rejected"