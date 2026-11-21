#!/bin/bash
# Run from the sysadmin VM shell (e.g. "run bash" from admin, or [sysadmin-vm:0_RPx:~]$).
# Deletes the listed cert files on every VM/host of every node in the chassis.
# Usage: ./del_certs.sh [-n]   (-n = dry run, only list matches)

FILES=("emSign_ECC_Root_CA_-_G3.crt" "Comodo_AAA_Services_root.crt")
DRY=0
[ "$1" = "-n" ] && DRY=1

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"

# Command executed on each Linux instance
PAYLOAD=$(cat <<EOF
DRY=$DRY
CONF=/etc/ca-certificates.conf
PAT='(emSign_ECC_Root_CA_-_G3\.crt|Comodo_AAA_Services_root\.crt)'
if [ -f "\$CONF" ]; then
    echo "-- \$CONF entries:"
    grep -E "\$PAT" "\$CONF"
    [ "\$DRY" -eq 0 ] && sed -i -E "/\$PAT/ s/^([^!])/!\1/" "\$CONF"
fi
[ "\$(id -u)" -ne 0 ] && echo "WARNING: not root, deletes may fail"
for f in \$(find / -xdev \( -type f -o -type l \) \( -name '${FILES[0]}' -o -name '${FILES[0]%.crt}.pem' -o -name '${FILES[1]}' -o -name '${FILES[1]%.crt}.pem' \) -not -path '/proc/*' 2>/dev/null); do
    echo "found: \$f"
    [ "\$DRY" -eq 0 ] && { rm -f "\$f" && echo "deleted: \$f" || echo "FAILED: \$f"; }
done
if [ "\$DRY" -eq 0 ]; then
    update-ca-certificates --fresh >/dev/null 2>&1
    echo "-- Validation (expect: ls: cannot access '/etc/ssl/certs/...pem': No such file or directory):"
    ls -l /etc/ssl/certs/Comodo_AAA_Services_root.pem 2>&1
    ls -l /etc/ssl/certs/emSign_ECC_Root_CA_-_G3.pem 2>&1
fi
EOF
)
# Base64 avoids quoting problems across nested ssh hops
B64=$(printf '%s\n' "$PAYLOAD" | base64 | tr -d '\n')
CMD="echo $B64 | base64 -d | sh"

# Targets from ARP: every *_admin / *_xr / my_host entry (active nodes only)
TARGETS=$(arp 2>/dev/null | awk 'NR>1 && $1 ~ /^(sc|fc|lc|rp)[0-9]+_(admin|xr)$/ {print $1}' | sort -u)

echo "== Local sysadmin VM ($(hostname)) =="
eval "$CMD"

echo "== Local host (my_host) =="
ssh $SSH_OPTS my_host "$CMD"

for t in $TARGETS; do
    echo "== $t =="
    ssh $SSH_OPTS "$t" "$CMD"
    # Each *_admin node also has its own host OS, reachable via my_host from that sysadmin VM
    case "$t" in
        *_admin)
            echo "== ${t%_admin} host =="
            ssh $SSH_OPTS "$t" "ssh $SSH_OPTS my_host '$CMD'"
            ;;
    esac
done

# Local XR VM and standby RP/RSP are covered via arp (rpX_xr / rpX_admin).
# The active-RP local XR VM appears in arp too (e.g. rp0_xr).
echo "Done. $([ "$DRY" -eq 1 ] && echo '(dry run, nothing deleted)')"