#!/bin/bash
# Remove eMudhra-related root certificates on every node of a Cisco ASR 9000
# (XR VM, sysadmin VM and host of RP/RSP, LCs, FCs, standby RP/RSP).
# Run from the active RP XR VM bash shell.  Use -n for a dry run.

DRY_RUN=0
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR"
CERTS=("emSign_ECC_Root_CA_-_G3.crt" "Comodo_AAA_Services_root.crt")
PATTERN='Comodo_AAA_Services_root.crt\|emSign_ECC_Root_CA_-_G3.crt'
CONF=/etc/ca-certificates.conf

usage() {
    echo "Usage: $0 [-n] [-h]"
    echo "  -n  dry run: only print the commands that would be executed"
    echo "  -h  show this help"
}

while getopts "nh" opt; do
    case "$opt" in
        n) DRY_RUN=1 ;;
        h) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done

# Executed on every node (locally or piped over ssh).
node_work() {
    run() {
        if [ "$DRY_RUN" = 1 ]; then echo "[dry-run] $*"; else "$@"; fi
    }

    echo "-- Entries found in $CONF:"
    grep "$PATTERN" "$CONF" || echo "   (none)"

    # Prepend "!" to matching lines that are not already disabled
    if grep -q "^[^!].*\($PATTERN\)" "$CONF" 2>/dev/null; then
        run sed -i "/$PATTERN/ s/^\([^!]\)/!\1/" "$CONF"
    fi

    # Remove the certificate files (and symlinks) wherever they live
    for c in "${CERTS[@]}"; do
        for f in $(find /usr/share/ca-certificates /usr/local/share/ca-certificates \
                        /etc/ssl/certs -name "$c" 2>/dev/null); do
            run rm -f "$f"
        done
    done

    run update-ca-certificates
}

# Executes node_work on a remote node via ssh
remote_node() {
    local node="$1"
    chvrf 0 ssh $SSH_OPTS "root@$node" "bash -s" <<EOF
DRY_RUN=$DRY_RUN
CERTS=(${CERTS[@]})
PATTERN='$PATTERN'
CONF=$CONF
$(declare -f node_work)
node_work
EOF
}

[ "$DRY_RUN" = 1 ] && echo "*** DRY RUN: no changes will be made ***"

echo "===== local node (this Admin VM) ====="
node_work

# arp entries: <node>_xr / _admin / _host on all other nodes (+ my_host); any name containing "ipu" or an (incomplete) entry is skipped
nodes=$(chvrf 0 arp 2>/dev/null | awk 'NR>1 && $1 !~ /ipu/ && $0 !~ /incomplete/ && $1 ~ /^[A-Za-z0-9]+_(xr|admin|host)$/ {print $1}' | sort -u)

if [ -z "$nodes" ]; then
    echo "No nodes found in 'chvrf 0 arp' output" >&2
    exit 1
fi

for node in $nodes; do
    echo "===== $node ====="
    remote_node "$node" || echo "!! failed on $node" >&2
done
