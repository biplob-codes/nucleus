#!/usr/bin/env bash
# leakcheck.sh - run a command, then report anything it left behind on the host.
# Normally called via `make check`.

set -u

CG_ROOT=/sys/fs/cgroup/nucleus

if [[ $EUID -ne 0 ]]; then
    echo "run with sudo (make check does this for you)" >&2
    exit 2
fi
[[ "${1:-}" == "--" ]] && shift
if [[ $# -lt 1 ]]; then
    echo "usage: leakcheck.sh -- <command> [args...]" >&2
    exit 2
fi

if [[ -t 1 ]]; then
    RED=$'\e[31m'; GREEN=$'\e[32m'; BOLD=$'\e[1m'; DIM=$'\e[2m'; OFF=$'\e[0m'
else
    RED=; GREEN=; BOLD=; DIM=; OFF=
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

snapshot() {
    local d=$1 host_ns p ns
    mkdir -p "$d"
    find "$CG_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'nuc-*' 2>/dev/null | sort > "$d/cgroups"
    ip -o link show | awk '{print $2}' | sed 's/[@:].*//' | sort > "$d/links"
    iptables -t nat -S 2>&1 | sort > "$d/iptables"
    findmnt -rn -o TARGET,FSTYPE,SOURCE 2>/dev/null | sort > "$d/mounts"
    cat /proc/sys/net/ipv4/ip_forward > "$d/ip_forward"

    host_ns=$(readlink /proc/$$/ns/pid)
    : > "$d/procs"
    for p in /proc/[0-9]*; do
        ns=$(readlink "$p/ns/pid" 2>/dev/null) || continue
        [[ "$ns" == "$host_ns" ]] && continue
        printf '%s %s\n' "${p#/proc/}" "$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)" >> "$d/procs"
    done
    sort -o "$d/procs" "$d/procs"

    if [[ -n "${LEAK_ROOTFS:-}" && -d "$LEAK_ROOTFS" ]]; then
        ls -A "$LEAK_ROOTFS" | sort > "$d/rootfs"
    else
        : > "$d/rootfs"
    fi
}

# name | what it means in plain words
CHECKS=(
  "cgroups|cgroup directory not removed (cleanup_cgroup failed)"
  "links|network interface left on the host (veth)"
  "iptables|firewall/NAT rule left behind"
  "mounts|mount left on the host"
  "ip_forward|ip_forward sysctl changed and not restored"
  "procs|process still alive inside a container namespace"
  "rootfs|extra file/dir left inside your rootfs (e.g. olddir)"
)

snapshot "$tmp/before"

echo "${BOLD}>>> running: $*${OFF}"
"$@"
rc=$?
echo "${BOLD}>>> container exited with status $rc${OFF}"
sleep 1   # kernel removes veth asynchronously
snapshot "$tmp/after"

echo
echo "${BOLD}=========== LEAK REPORT ===========${OFF}"
dirty=0
for entry in "${CHECKS[@]}"; do
    name=${entry%%|*}; desc=${entry#*|}
    if diff "$tmp/before/$name" "$tmp/after/$name" > "$tmp/d"; then
        printf '%s[ OK ]%s %s\n' "$GREEN" "$OFF" "$name"
    else
        dirty=1
        printf '%s[LEAK]%s %s  %s-> %s%s\n' "$RED" "$OFF" "$name" "$DIM" "$desc" "$OFF"
        grep '^>' "$tmp/d" | sed 's/^> /         appeared:    /'
        grep '^<' "$tmp/d" | sed 's/^< /         disappeared: /'
    fi
done
echo "==================================="
if [[ $dirty -eq 0 ]]; then
    echo "${GREEN}${BOLD}CLEAN${OFF}: nothing left behind."
    exit 0
fi
echo "${RED}${BOLD}DIRTY${OFF}: items marked [LEAK] survived the run."
exit 1