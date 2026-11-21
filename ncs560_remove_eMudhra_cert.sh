#!/bin/bash
# NCS 560: run from the sysadmin VM shell of the ACTIVE RP (admin -> run).
# Cleans emSign ECC G3 and Comodo AAA root certs on every instance of each RP present (0 and 1):
#   sysadmin-vm:0_RPx, host:0_RPx (chvrf 0 ssh root@10.0.2.2) and xr-vm_node0_RPx_CPU0.
# Usage: ./ncs560_remove_eMudhra_cert.sh [-n] [-p]
#   -n  dry run, only list matches
#   -p  try setenforce 0 during cleanup (restored afterwards; skipped with a warning if denied)

DRY=0
PERM=0
for a in "$@"; do
    case "$a" in
        -n) DRY=1 ;;
        -p) PERM=1 ;;
    esac
done

SSH_OPTS="-n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR"
HOST_IP=10.0.2.2

# Per-RP internal addressing (from "show vm"): RP0 192.0.0.x, RP1 192.0.4.x
# sysadmin = .1, xr-vm = .4
RPS="0 1"
sys_ip() { [ "$1" = "0" ] && echo 192.0.0.1 || echo 192.0.4.1; }
xr_ip()  { [ "$1" = "0" ] && echo 192.0.0.4 || echo 192.0.4.4; }

read -r -d '' PAYLOAD <<'EOF'
DRY="$1"
PERM="$2"
PREV=$(getenforce 2>/dev/null)
if [ "$DRY" = "0" ] && [ "$PERM" = "1" ] && [ "$PREV" = "Enforcing" ]; then
    if setenforce 0 2>/dev/null; then
        echo "-- SELinux set to permissive (was Enforcing)"
        trap 'setenforce 1; echo "-- SELinux restored to Enforcing"' EXIT
    else
        echo "-- WARNING: setenforce denied by policy; continuing in Enforcing mode"
    fi
fi
CONF=/etc/ca-certificates.conf
echo "-- node: $(hostname)"
[ "$(id -u)" != "0" ] && echo "WARNING: not root, deletes may fail"
if [ -f "$CONF" ]; then
    echo "-- $CONF entries:"
    grep -E 'emSign_ECC_Root_CA_-_G3\.crt|Comodo_AAA_Services_root\.crt' "$CONF"
    [ "$DRY" = "0" ] && sed -i -E '/emSign_ECC_Root_CA_-_G3\.crt|Comodo_AAA_Services_root\.crt/ s/^([^!])/!\1/' "$CONF"
fi
if [ "$DRY" = "0" ]; then
    echo "-- update-ca-certificates --fresh:"
    update-ca-certificates --fresh 2>&1 | tail -5
fi
find / \( -path /proc -o -path /sys -o -path /dev -o -path /mnt/fuse -o -path /qsm \) -prune -o \( -type f -o -type l \) \( -name 'emSign_ECC_Root_CA_-_G3.crt' -o -name 'emSign_ECC_Root_CA_-_G3.pem' -o -name 'Comodo_AAA_Services_root.crt' -o -name 'Comodo_AAA_Services_root.pem' \) -print 2>/dev/null | while read -r f; do
    echo "found: $f"
    if [ "$DRY" = "0" ]; then
        if rm -f "$f"; then echo "deleted: $f"; else
            echo "FAILED: $f"
            d=$(dirname "$f")
            echo "   diag: $(ls -ldZ "$d" 2>&1)"
            echo "   diag: $(lsattr -d "$d" "$f" 2>&1 | tr '\n' ' ')"
            echo "   diag: $(df "$d" 2>&1 | tail -1) | selinux=$(getenforce 2>&1)"
        fi
    fi
done
if [ "$DRY" = "0" ]; then
    echo "-- Validation (expect: No such file or directory):"
    ls -l /etc/ssl/certs/Comodo_AAA_Services_root.pem 2>&1
    ls -l /etc/ssl/certs/emSign_ECC_Root_CA_-_G3.pem 2>&1
fi
true
EOF

B64=$(printf '%s\n' "$PAYLOAD" | base64 | tr -d '\n')
CMD="echo $B64 | base64 -d | sh -s $DRY $PERM"

# Run CMD on a remote IP through the default VRF (chvrf 0)
rssh() { chvrf 0 ssh $SSH_OPTS "root@$1" "$2"; }

LOCAL_IPS=$(ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
is_local() { echo "$LOCAL_IPS" | grep -qx "$1"; }

echo "== Local sysadmin VM ($(hostname)) =="
sh -c "$CMD"

echo "== Local host (via $HOST_IP) =="
rssh $HOST_IP "$CMD" || echo "FAILED to reach local host"

for rp in $RPS; do
    S=$(sys_ip $rp); X=$(xr_ip $rp)

    if ! is_local "$S"; then
        echo "== RP$rp sysadmin-vm ($S) =="
        if rssh "$S" "true" >/dev/null 2>&1; then
            rssh "$S" "$CMD"
            echo "== RP$rp host (via $S -> $HOST_IP) =="
            rssh "$S" "chvrf 0 ssh $SSH_OPTS root@$HOST_IP '$CMD'" || echo "FAILED RP$rp host"
        else
            echo "RP$rp not reachable (absent or down), skipping sysadmin and host"
            continue
        fi
    fi

    echo "== RP$rp xr-vm ($X) =="
    rssh "$X" "$CMD" || echo "FAILED RP$rp xr-vm"
done

if [ "$DRY" = "1" ]; then
    echo "Done. (dry run, nothing deleted)"
else
    echo "Done."
fi
