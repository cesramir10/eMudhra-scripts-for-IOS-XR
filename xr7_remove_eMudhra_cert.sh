#!/bin/bash
# xr7_remove_eMudhra_cert.sh
# Removes emSign ECC Root CA G3 and Comodo AAA Services root certs from the
# local node and all REACHABLE nodes (RP/RSP, LC, SC, FC) of a Cisco XR7 router.
# Run from the XR7 host Linux shell ("run" from XR CLI).
#
# Usage: ./xr7_remove_eMudhra_cert.sh [-n] [-h]
#   -n  dry run: only print what would be done

CERTS=("emSign_ECC_Root_CA_-_G3.crt" "Comodo_AAA_Services_root.crt")
CONF="/etc/ca-certificates.conf"
SEARCH_DIRS="/etc/ssl/certs /usr/share/ca-certificates /usr/local/share/ca-certificates"
VLAN="3074"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR"

DRY=0
usage() { echo "Usage: $0 [-n] [-h]   (-n = dry run)"; }
while getopts "nh" opt; do
    case "$opt" in
        n) DRY=1 ;;
        h) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done

# Node-level work. Executed locally and piped to remote nodes via "bash -s".
node_work() {
    DRY="$1"
    CONF="/etc/ca-certificates.conf"
    DIRS="/etc/ssl/certs /usr/share/ca-certificates /usr/local/share/ca-certificates"
    N1="emSign_ECC_Root_CA_-_G3.crt"
    N2="Comodo_AAA_Services_root.crt"

    run() {
        if [ "$DRY" -eq 1 ]; then echo "[DRY-RUN] $*"; else echo "[RUN] $*"; "$@"; fi
    }

    echo "Node: $(hostname)"

    echo "-- Matching lines in $CONF:"
    grep "Comodo_AAA_Services_root.crt\|emSign_ECC_Root_CA_-_G3.crt" "$CONF" \
        || echo "   (none)"

    # Prepend "!" to matching lines not already disabled
    if [ "$DRY" -eq 1 ]; then
        echo "[DRY-RUN] sed -i '/Comodo_AAA_Services_root.crt\|emSign_ECC_Root_CA_-_G3.crt/ s/^\([^!]\)/!\1/' $CONF"
    else
        echo "[RUN] prepend '!' to matching lines in $CONF"
        sed -i '/Comodo_AAA_Services_root.crt\|emSign_ECC_Root_CA_-_G3.crt/ s/^\([^!]\)/!\1/' "$CONF"
    fi

    # Remove files (including symlinks) with the affected names
    found=0
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        found=1
        run rm -f "$f"
    done < <(find $DIRS \( -type f -o -type l \) \( -name "$N1" -o -name "$N2" \) 2>/dev/null)
    [ "$found" -eq 0 ] && echo "-- No certificate files found"

    run update-ca-certificates
    echo "Done: $(hostname)"
}

[ "$DRY" -eq 1 ] && echo "*** DRY RUN: no changes will be made ***"

# Reachable peer nodes (empty on single-node systems)
PEERS=$(ip neigh show nud reachable 2>/dev/null | grep "$VLAN" | awk '{print $1}' | sort -u)

echo "================ LOCAL NODE ================"
node_work "$DRY"

if [ -z "$PEERS" ]; then
    echo "No reachable peer nodes found; only the local node was processed."
    exit 0
fi

rc=0
for ip in $PEERS; do
    echo
    echo "================ REMOTE NODE $ip ================"
    # shellcheck disable=SC2086
    if ! { declare -f node_work; echo "node_work $DRY"; } | ssh $SSH_OPTS "root@$ip" "bash -s"; then
        echo "ERROR: failed to process $ip" >&2
        rc=1
    fi
done
exit $rc
