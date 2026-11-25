#!/usr/bin/env bash
# leakcheck.sh - host-state checker and test suite for Nucleus.
#
#   ./leakcheck.sh check -- <cmd...>   run a command, then report what it left behind
#   ./leakcheck.sh test [ID|PHASE]...  run the roadmap tests (all, one id, or a phase digit)
#   ./leakcheck.sh list                list every test with its roadmap id
#   ./leakcheck.sh explain ID          what that test proves, and what "fixed" looks like
#   ./leakcheck.sh status              show everything Nucleus currently owns on the host
#   ./leakcheck.sh clean               remove leftovers from earlier crashed runs
#
# Normally you call it through make: make check / make test / make status / make clean-leaks
#
# Every test id (1.1, 2.3, 5.4 ...) is the same id as the task in ROADMAP.md.
# A test passing means "the host looks the way the roadmap says it should".

set -u

# ----------------------------------------------------------------- settings
CG_ROOT=${CG_ROOT:-/sys/fs/cgroup/nucleus}
CG_REL=${CG_ROOT#/sys/fs/cgroup}
NUC_BIN=${NUC_BIN:-./container}
NUC_HOST=${NUC_HOST:-nucleus}
ROOTFS=${LEAK_ROOTFS:-}
SRC_DIR=${SRC_DIR:-.}
NAT_SUBNETS=${NUC_SUBNETS:-12.200.1.0/24}   # subnets whose MASQUERADE rules `clean` may delete
LINK_REGEX=${LINK_REGEX:-^nuc-}             # host interfaces `clean` may delete (bridge nuc0 is kept)
RUN_TIMEOUT=${LEAK_TIMEOUT:-20}             # max seconds for one container run
STOP_TIMEOUT=${LEAK_STOP_TIMEOUT:-15}       # how long the runtime may take to react to a signal
SETTLE=${LEAK_SETTLE:-1}                    # the kernel removes veth asynchronously
ITER=${LEAK_ITER:-10}                       # iterations for the race test
STARTUP=${LEAK_STARTUP:-2}                  # seconds to wait for a container to boot in pty test

# ------------------------------------------------- THE ONLY PLACE THAT KNOWS THE CLI
# When you change your command line (roadmap 2.6), edit this one function.
mk_argv() { # hostname rootfs
	ARGV=("$NUC_BIN" -h "$1" -fs "$2")
}

# ------------------------------------------------------------------- output
if [[ -t 1 ]]; then
	RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BOLD=$'\e[1m'; DIM=$'\e[2m'; OFF=$'\e[0m'
else
	RED=; GREEN=; YELLOW=; BOLD=; DIM=; OFF=
fi

die() { echo "leakcheck: $*" >&2; exit 2; }
have() { command -v "$1" >/dev/null 2>&1; }

T=$(mktemp -d) || exit 2
ORIG_IPF=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)
IPF_CHANGED=
BG_PID=
RUNN=0

on_exit() {
	exec 9>&-
	if [[ -n $BG_PID ]] && alive "$BG_PID"; then kill -9 "$BG_PID" 2>/dev/null; fi
	if [[ -n $IPF_CHANGED ]]; then echo "$ORIG_IPF" >/proc/sys/net/ipv4/ip_forward 2>/dev/null; fi
	rm -rf "$T"
}
trap on_exit EXIT
trap 'exit 130' INT TERM

# --------------------------------------------------------- process helpers
alive() { # pid -> true if running (a zombie counts as gone)
	local s
	s=$(sed 's/^.*) //; s/ .*//' "/proc/$1/stat" 2>/dev/null) || return 1
	[[ -n $s && $s != Z ]]
}

wait_gone() { # pid seconds
	local i n=$(($2 * 10))
	for ((i = 0; i < n; i++)); do
		alive "$1" || return 0
		sleep 0.1
	done
	return 1
}

wait_text() { # file text seconds
	local i n=$((${3:-8} * 5))
	for ((i = 0; i < n; i++)); do
		grep -q -- "$2" "$1" 2>/dev/null && return 0
		sleep 0.2
	done
	return 1
}

nuc_procs() { # processes that live inside a nuc-* cgroup
	local p
	for p in /proc/[0-9]*; do
		grep -q "^0::${CG_REL}/" "$p/cgroup" 2>/dev/null || continue
		printf '%s %s\n' "${p#/proc/}" "$(tr '\0' ' ' <"$p/cmdline" 2>/dev/null)"
	done | sort
}

set_ipf() { echo "$1" >/proc/sys/net/ipv4/ip_forward; IPF_CHANGED=1; }

# ---------------------------------------------------------------- snapshot
snapshot() {
	local d=$1
	mkdir -p "$d"
	{ find "$CG_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'nuc-*' 2>/dev/null || true; } | sort >"$d/cgroups"
	if [[ -d $CG_ROOT ]]; then echo present; else echo absent; fi >"$d/cgroup_parent"
	if have ip; then
		ip -o link show 2>/dev/null | awk '{print $2}' | sed 's/[@:].*//' | sort >"$d/links"
	else
		echo "(ip not installed)" >"$d/links"
	fi
	if have iptables; then
		iptables -t nat -S >"$d/nat_raw" 2>&1
		sort "$d/nat_raw" >"$d/iptables_nat"
		{ grep '^-A' "$d/nat_raw" | sort | uniq -d; } >"$d/iptables_dups" 2>/dev/null || true
		iptables -S 2>&1 | sort >"$d/iptables_filter"
	else
		echo "(iptables not installed)" | tee "$d/iptables_nat" "$d/iptables_filter" >/dev/null
		: >"$d/iptables_dups"
	fi
	findmnt -rn -o TARGET,FSTYPE,SOURCE 2>/dev/null | sort >"$d/mounts"
	cat /proc/sys/net/ipv4/ip_forward >"$d/ip_forward" 2>/dev/null
	nuc_procs >"$d/procs"
	if [[ -n $ROOTFS && -d $ROOTFS ]]; then
		{
			find "$ROOTFS" -xdev ! -type d -printf '%p %y %s\n'
			find "$ROOTFS" -xdev -type d -printf '%p d\n'
		} 2>/dev/null | sort >"$d/rootfs"
	else
		: >"$d/rootfs"
	fi
}

# name|kind|what it means|roadmap ids      kind: diff = before/after must match,
#                                                empty = must be empty afterwards,
#                                                warn = shown but never fails
CHECKS=(
	"cgroups|diff|cgroup directory not removed|1.3 2.3 3.2"
	"cgroup_parent|warn|parent cgroup was deleted by the run (races with a second container)|3.2"
	"links|diff|network interface left on the host (veth/bridge)|1.3 5.4"
	"iptables_nat|diff|NAT rule left behind|1.3 5.3"
	"iptables_dups|empty|the same NAT rule exists more than once|5.3"
	"iptables_filter|diff|firewall FORWARD/filter rule left behind|5.3"
	"mounts|diff|mount leaked into the host mount namespace|4.1"
	"ip_forward|diff|ip_forward sysctl changed and never restored|5.3"
	"procs|diff|process still alive inside a nuc-* cgroup|2.1 2.3 2.4"
	"rootfs|diff|your rootfs directory was modified (olddir, files the container wrote)|4.1 4.4"
)

# compare BEFORE AFTER full|quiet   -> sets DIRTY_N, WARN_N, DIRTY_NAMES, REPORT
compare() {
	local b=$1 a=$2 mode=$3 entry name kind desc refs app dis allow var lines
	local r=$RED g=$GREEN y=$YELLOW d=$DIM o=$OFF
	if [[ $mode == quiet ]]; then r=; g=; y=; d=; o=; fi
	DIRTY_N=0; WARN_N=0; DIRTY_NAMES=""; REPORT=""
	for entry in "${CHECKS[@]}"; do
		IFS='|' read -r name kind desc refs <<<"$entry"
		var="LEAK_ALLOW_${name^^}"
		allow=${!var:-}
		app=; dis=
		if [[ $kind == empty ]]; then
			app=$(cat "$a/$name")
			[[ -n $allow && -n $app ]] && app=$(grep -Ev -- "$allow" <<<"$app")
		else
			diff "$b/$name" "$a/$name" >"$T/d" 2>&1
			app=$(grep '^>' "$T/d" | sed 's/^> //')
			dis=$(grep '^<' "$T/d" | sed 's/^< //')
			if [[ -n $allow ]]; then
				[[ -n $app ]] && app=$(grep -Ev -- "$allow" <<<"$app")
				[[ -n $dis ]] && dis=$(grep -Ev -- "$allow" <<<"$dis")
			fi
		fi
		if [[ -z $app && -z $dis ]] || { [[ $kind == warn ]] && [[ -z $dis ]]; }; then
			[[ $mode == full && $kind != warn ]] && REPORT+=$(printf '%s[ OK ]%s %s\n' "$g" "$o" "$name")$'\n'
			continue
		fi
		if [[ $kind == warn ]]; then
			WARN_N=$((WARN_N + 1))
			REPORT+=$(printf '%s[WARN]%s %s  %s-> %s (roadmap %s)%s\n' "$y" "$o" "$name" "$d" "$desc" "$refs" "$o")$'\n'
			continue
		fi
		DIRTY_N=$((DIRTY_N + 1)); DIRTY_NAMES+="$name "
		REPORT+=$(printf '%s[LEAK]%s %s  %s-> %s (roadmap %s)%s\n' "$r" "$o" "$name" "$d" "$desc" "$refs" "$o")$'\n'
		[[ -n $app ]] && REPORT+=$(sed 's/^/         appeared:    /' <<<"$app")$'\n'
		[[ -n $dis ]] && REPORT+=$(sed 's/^/         disappeared: /' <<<"$dis")$'\n'
	done
}

# ---------------------------------------------------------------- cleaning
do_clean() { # [quiet]
	local d n p s rule
	local say=1; [[ ${1:-} == quiet ]] && say=0
	for d in "$CG_ROOT"/nuc-*; do
		[[ -d $d ]] || continue
		(( say )) && echo "removing cgroup $d"
		if [[ -w $d/cgroup.kill ]]; then
			echo 1 >"$d/cgroup.kill" 2>/dev/null
		else
			while read -r p; do kill -9 "$p" 2>/dev/null; done <"$d/cgroup.procs"
		fi
		for _ in $(seq 20); do
			[[ -z $(cat "$d/cgroup.procs" 2>/dev/null) ]] && break
			sleep 0.1
		done
		rmdir "$d" 2>/dev/null
	done
	if have ip; then
		for n in $(ip -o link show | awk '{print $2}' | sed 's/[@:].*//' | grep -E "$LINK_REGEX"); do
			(( say )) && echo "removing interface $n"
			ip link del "$n" 2>/dev/null
		done
	fi
	if have iptables; then
		for s in $NAT_SUBNETS; do
			while rule=$(iptables -t nat -S POSTROUTING 2>/dev/null | grep -F -- "-s $s " | grep MASQUERADE | head -n1) && [[ -n $rule ]]; do
				(( say )) && echo "removing NAT rule: $rule"
				# shellcheck disable=SC2086
				iptables -t nat ${rule/-A/-D} || break
			done
		done
	fi
	[[ -n $ROOTFS ]] && rmdir "$ROOTFS/olddir" 2>/dev/null
	return 0
}

# ------------------------------------------------------------ run helpers
SAN_HIT=0; SAN_TEXT=""
scan_sanitizer() {
	if grep -qE 'AddressSanitizer|LeakSanitizer|runtime error:' "$1" 2>/dev/null; then
		SAN_HIT=1
		SAN_TEXT=$(grep -E 'AddressSanitizer|LeakSanitizer|runtime error:' "$1" | head -n 3)
	fi
}

# run_nuc "<what the container shell reads on stdin>" [VAR=value ...]   uses ARGV
# sets RC, OUT (stdout file), ERR (stderr file)
run_nuc() {
	local input=$1; shift
	RUNN=$((RUNN + 1)); OUT=$T/out.$RUNN; ERR=$T/err.$RUNN
	printf '%s' "$input" | timeout -k 3 "$RUN_TIMEOUT" env "$@" "${ARGV[@]}" >"$OUT" 2>"$ERR"
	RC=${PIPESTATUS[1]}
	scan_sanitizer "$ERR"
	if [[ $RC -eq 124 || $RC -eq 137 ]]; then do_clean quiet; fi
}

# same, but under strace (events = comma list); falls back to a plain run
TRACED=0
run_maybe_traced() { # events logfile input
	if have strace; then
		TRACED=1
		RUNN=$((RUNN + 1)); OUT=$T/out.$RUNN; ERR=$T/err.$RUNN
		printf '%s' "$3" | timeout -k 3 "$RUN_TIMEOUT" env ASAN_OPTIONS=detect_leaks=0 \
			strace -f -qq -o "$2" -e "trace=$1" "${ARGV[@]}" >"$OUT" 2>"$ERR"
		RC=${PIPESTATUS[1]}
		scan_sanitizer "$ERR"
		if [[ $RC -eq 124 || $RC -eq 137 ]]; then do_clean quiet; fi
	else
		TRACED=0
		: >"$2"
		run_nuc "$3"
	fi
}

# container started in the background, in its own session, stdin = a fifo we control
bg_start() {
	RUNN=$((RUNN + 1))
	BG_FIFO=$T/fifo.$RUNN; BG_OUT=$T/bg.out.$RUNN; BG_ERR=$T/bg.err.$RUNN
	mkfifo "$BG_FIFO"
	exec 9<>"$BG_FIFO"
	setsid "${ARGV[@]}" <"$BG_FIFO" >"$BG_OUT" 2>"$BG_ERR" 9>&- &
	BG_PID=$!
	disown "$BG_PID" 2>/dev/null
}
bg_send() { printf '%s\n' "$1" >&9; }
bg_ready() { bg_send 'echo READY_$((40+2))'; wait_text "$BG_OUT" READY_42 10; }
bg_stop() {
	exec 9>&-
	if alive "$BG_PID"; then kill -9 "$BG_PID" 2>/dev/null; fi
	scan_sanitizer "$BG_ERR"
	BG_PID=
	do_clean quiet
}

# ------------------------------------------------------------ test results
declare -A T_PHASE T_TITLE T_WHY T_FIXED T_DEFER
ORDER=()
reg() { # id phase title why fixed [deferred]
	ORDER+=("$1"); T_PHASE[$1]=$2; T_TITLE[$1]=$3; T_WHY[$1]=$4; T_FIXED[$1]=$5; T_DEFER[$1]=${6:-0}
}

R_FAIL=0; R_SKIP=0; MSGS=()
ok()   { MSGS+=("${GREEN}✓${OFF} $*"); }
bad()  { R_FAIL=1; MSGS+=("${RED}✗${OFF} $*"); }
note() { MSGS+=("${DIM}· $*${OFF}"); }
skip() { R_SKIP=1; MSGS+=("${YELLOW}- $*${OFF}"); }
evidence() { # file [lines]
	local l
	[[ -r $1 ]] || return 0
	while IFS= read -r l; do MSGS+=("${DIM}    $l${OFF}"); done < <(head -n "${2:-5}" "$1")
}
evidence_text() { # text
	local l
	while IFS= read -r l; do MSGS+=("${DIM}    $l${OFF}"); done <<<"$1"
}

need_rootfs() { [[ -d $ROOTFS ]] || { skip "LEAK_ROOTFS is not set to a directory"; return 1; }; }
need_tool()   { have "$1" || { skip "needs '$1' (sudo dnf install $2)"; return 1; }; }

leak_begin() { rm -rf "$T/lb"; snapshot "$T/lb"; }
leak_end() {
	sleep "$SETTLE"
	rm -rf "$T/la"; snapshot "$T/la"
	compare "$T/lb" "$T/la" quiet
	if (( DIRTY_N > 0 )); then
		bad "host is not clean afterwards: ${DIRTY_NAMES}"
		evidence_text "$REPORT"
	else
		ok "host state identical before and after"
	fi
	(( WARN_N > 0 )) && note "$(head -n1 <<<"$REPORT")"
	do_clean quiet
}

# --------------------------------------------------------------- probes
# Scripts typed into the container shell. They must NOT touch /dev/null
# (it may not exist yet, and a redirect would create a file in your rootfs).
read -r -d '' PROBE_BASIC <<'EOF'
echo "P:pid=$$"
echo "P:hostname=$(hostname)"
echo "P:procs=$(ls /proc | grep -c '^[0-9]')"
echo "P:ifaces=$(awk 'NR>2{gsub(":","",$1);printf "%s ",$1}' /proc/net/dev)"
exit
EOF

read -r -d '' PROBE_PROC <<'EOF'
if [ -w /proc/sys ]; then echo P:procsys=writable; else echo P:procsys=readonly; fi
if [ -w /proc/sysrq-trigger ]; then echo P:sysrq=writable; else echo P:sysrq=readonly; fi
if [ -s /proc/kcore ]; then echo P:kcore=exposed; else echo P:kcore=masked; fi
exit
EOF

read -r -d '' PROBE_DEV <<'EOF'
for d in null zero urandom random tty full; do
  if [ -c /dev/$d ]; then echo P:dev_$d=ok; else echo P:dev_$d=missing; fi
done
if [ -d /dev/pts ]; then echo P:dev_pts=ok; else echo P:dev_pts=missing; fi
if [ -d /dev/shm ]; then echo P:dev_shm=ok; else echo P:dev_shm=missing; fi
if [ -w /tmp ]; then echo P:tmp=ok; else echo P:tmp=missing; fi
if [ -d /sys/kernel ]; then echo P:sys=ok; else echo P:sys=missing; fi
exit
EOF

read -r -d '' PROBE_ENV <<'EOF'
echo "P:secret=${LEAKCHECK_SECRET:-absent}"
exit
EOF

read -r -d '' PROBE_NAT <<'EOF'
if out=$(ping -c1 -W3 1.1.1.1 2>&1); then echo P:nat=ok; else echo P:nat=fail; fi
exit
EOF

read -r -d '' PROBE_DNS <<'EOF'
echo "P:resolv=$(grep '^nameserver' /etc/resolv.conf | tr '\n' ' ')"
if out=$(ping -c1 -W3 example.com 2>&1); then echo P:dns=ok; else echo P:dns=fail; fi
exit
EOF

read -r -d '' PROBE_OOM <<'EOF'
awk 'BEGIN{s="x"; for(i=0;i<27;i++) s = s s; print "SURVIVED", length(s)}'
echo END_OOM
exit
EOF

read -r -d '' PROBE_PIDS <<'EOF'
i=0
while [ $i -lt 200 ]; do sleep 4 & i=$((i+1)); done
echo DONE_SPAWN
EOF

pval() { sed -n "s/^P:$1=//p" "$OUT" | head -n1; }

# ====================================================================
#                               THE TESTS
# ====================================================================
# Each test id = roadmap task id. Register first (title, why it matters, what fixed looks like).

reg 0.1 0 "a plain run leaves the host exactly as it found it" \
	"every other guarantee builds on this: whatever a run acquires, it must release" \
	"all [ OK ] lines in the leak report"
t_0_1() {
	need_rootfs || return
	mk_argv "$NUC_HOST" "$ROOTFS"; leak_begin
	run_nuc $'exit\n'
	if (( RC == 0 )); then ok "container started and exited with 0"; else bad "container exit status $RC"; evidence "$ERR"; fi
	leak_end
}

reg 0.2 0 "the container's exit status is returned by the runtime" \
	"callers (scripts, make, you) need the real exit code of what ran inside" \
	"exit 7 inside gives 7 outside (guard rail - passes today, keep it passing)"
t_0_2() {
	need_rootfs || return
	mk_argv "$NUC_HOST" "$ROOTFS"
	run_nuc $'exit 7\n'
	if (( RC == 7 )); then ok "exit 7 inside -> 7 outside"; else bad "expected 7, got $RC"; evidence "$ERR"; fi
}

reg 0.4 0 "isolation sanity: pid 1, hostname, own /proc, own network namespace" \
	"if a refactor silently breaks a namespace, this tells you first" \
	"pid=1, hostname as given, a handful of processes, only lo plus one veth (guard rail)"
t_0_4() {
	need_rootfs || return
	mk_argv "$NUC_HOST" "$ROOTFS"
	run_nuc "$PROBE_BASIC"
	local pid host procs ifaces n
	pid=$(pval pid); host=$(pval hostname); procs=$(pval procs); ifaces=$(pval ifaces)
	[[ $pid == 1 ]] && ok "shell is PID 1" || bad "shell is PID '$pid', expected 1 (PID namespace broken)"
	[[ $host == "$NUC_HOST" ]] && ok "hostname is $NUC_HOST" || bad "hostname is '$host'"
	[[ -n $procs ]] && (( procs <= 10 )) && ok "/proc shows $procs processes (not the host's)" || bad "/proc shows '$procs' processes"
	n=$(wc -w <<<"$ifaces")
	if [[ " $ifaces " == *" lo "* ]] && (( n <= 2 )); then ok "network namespace has: $ifaces"; else bad "interfaces inside: '$ifaces' (host network visible?)"; fi
}

# ---------------------------------------------------------------- phase 1
reg 1.1 1 "no file descriptor is closed twice" \
	"two owners of one fd (conf and ledger) means close() runs twice; one day it closes someone else's file" \
	"strace shows no close(...) = -1 EBADF anywhere in a run"
t_1_1() {
	need_tool strace strace || return
	need_rootfs || return
	mk_argv "$NUC_HOST" "$ROOTFS"
	run_maybe_traced close "$T/s1.log" $'exit\n'
	grep -E 'close\([0-9]+\) += -1 EBADF' "$T/s1.log" >"$T/ebadf" 2>/dev/null
	if [[ -s $T/ebadf ]]; then bad "$(wc -l <"$T/ebadf") close() call(s) on an fd that was already closed"; evidence "$T/ebadf"
	else ok "every close() had a valid fd"; fi
}

reg 1.3a 1 "fault: moving the veth into the container fails -> nothing is left on the host" \
	"the ledger must also cover resources acquired halfway through a setup step" \
	"no [LEAK] lines; runtime exits non-zero with a clear message"
t_1_3a() {
	need_tool ip iproute || return
	need_rootfs || return
	local stub=$T/stub_ip real; real=$(command -v ip)
	mkdir -p "$stub"
	printf '#!/bin/sh\ncase "$*" in *" netns "*) echo "leakcheck: injected fault" >&2; exit 1;; esac\nexec %s "$@"\n' "$real" >"$stub/ip"
	chmod +x "$stub/ip"
	mk_argv "$NUC_HOST" "$ROOTFS"; leak_begin
	run_nuc $'exit\n' PATH="$stub:$PATH"
	if (( RC != 0 )); then ok "runtime reported failure (exit $RC)"; else bad "runtime pretended everything worked (exit 0)"; fi
	leak_end
}

reg 1.3b 1 "fault: the NAT step fails -> ip_forward is restored and nothing leaks" \
	"every global change (sysctl, firewall) needs an owner that undoes it, even on the failure path" \
	"ip_forward back to its old value, no [LEAK] lines"
t_1_3b() {
	need_tool iptables iptables-nft || return
	need_rootfs || return
	local stub=$T/stub_ipt; mkdir -p "$stub"
	printf '#!/bin/sh\necho "leakcheck: injected fault" >&2\nexit 1\n' >"$stub/iptables"
	chmod +x "$stub/iptables"
	set_ipf 0
	mk_argv "$NUC_HOST" "$ROOTFS"; leak_begin
	run_nuc $'exit\n' PATH="$stub:$PATH"
	if (( RC != 0 )); then ok "runtime reported failure (exit $RC)"; else bad "runtime pretended everything worked (exit 0)"; fi
	leak_end
	set_ipf "$ORIG_IPF"; IPF_CHANGED=
}

reg 1.4a 1 "a 70-character hostname is rejected before anything is created" \
	"validate input in the parent first; failing at the very end wastes and risks every resource made before it" \
	"non-zero exit and (with strace) no clone() with CLONE_NEW* flags happened"
t_1_4a() {
	need_rootfs || return
	local long; long=$(printf 'a%.0s' $(seq 70))
	mk_argv "$long" "$ROOTFS"; leak_begin
	run_maybe_traced clone,clone3 "$T/s14a.log" $'exit\n'
	if (( RC != 0 )); then ok "runtime refused the hostname (exit $RC)"; else bad "runtime accepted a 70-char hostname"; fi
	if (( TRACED )); then
		if grep -q CLONE_NEW "$T/s14a.log"; then bad "namespaces were created BEFORE the hostname was validated"; else ok "no container was created"; fi
	else note "install strace to also prove nothing was created before the check"; fi
	leak_end
}

reg 1.4b 1 "a rootfs without /bin/sh or /proc is rejected before anything is created" \
	"the parent can check the rootfs is usable; the child should never be the first to find out" \
	"non-zero exit with a message naming what is missing, no clone()"
t_1_4b() {
	need_rootfs || return
	local empty; empty=$(mktemp -d "$T/emptyroot.XXXX")
	mk_argv "$NUC_HOST" "$empty"; leak_begin
	run_maybe_traced clone,clone3 "$T/s14b.log" $'exit\n'
	if (( RC != 0 )); then ok "runtime refused an empty rootfs (exit $RC)"; else bad "runtime accepted a rootfs with no /bin/sh"; fi
	if (( TRACED )); then
		if grep -q CLONE_NEW "$T/s14b.log"; then bad "namespaces were created BEFORE the rootfs was validated"; else ok "no container was created"; fi
	fi
	evidence "$ERR" 2
	leak_end
}

reg 1.5 1 "error messages are real messages (no 'Success', no 'Unknown error 100x', no perror)" \
	"errno is only meaningful right after a failing syscall; mixing styles produces nonsense output" \
	"every bad invocation prints a clear one-line error; no perror() left in the source"
t_1_5() {
	need_rootfs || return
	local args name n
	local -a cases=("no arguments|" "-fs without value|-fs" "nonexistent rootfs|-fs /nonexistent/xyz")
	for n in "${cases[@]}"; do
		name=${n%%|*}; args=${n#*|}
		ARGV=("$NUC_BIN")
		# shellcheck disable=SC2206
		[[ -n $args ]] && ARGV+=($args)
		run_nuc ""
		if grep -qE 'Unknown error|: Success' "$ERR"; then bad "$name: misleading message"; evidence "$ERR" 2
		elif (( RC == 0 )); then bad "$name: exit status 0"
		elif [[ ! -s $ERR ]]; then bad "$name: failed silently"
		else ok "$name: $(head -n1 "$ERR")"; fi
	done
	if grep -n 'perror(' "$SRC_DIR"/*.c >"$T/perror" 2>/dev/null; then
		bad "perror() still used (use one error path)"; evidence "$T/perror" 3
	else ok "no perror() in the source"; fi
}

# ---------------------------------------------------------------- phase 2
reg 2.1a 2 "SIGTERM to the runtime: it shuts the container down and cleans up" \
	"today SIGTERM kills the runtime on the spot, so cleanup never runs and the shell keeps running" \
	"runtime exits within a few seconds AND the leak report is clean"
t_2_1a() {
	need_rootfs || return
	mk_argv "$NUC_HOST" "$ROOTFS"; leak_begin
	bg_start
	if ! bg_ready; then bad "container never became ready"; evidence "$BG_ERR"; bg_stop; return; fi
	kill -TERM "$BG_PID"
	if wait_gone "$BG_PID" "$STOP_TIMEOUT"; then ok "runtime exited after SIGTERM"; leak_end
	else bad "runtime still running ${STOP_TIMEOUT}s after SIGTERM"; fi
	bg_stop
}

reg 2.1b 2 "Ctrl-C (SIGINT to the whole process group): clean shutdown" \
	"the terminal sends SIGINT to the runtime AND the shell; the runtime currently dies first and abandons everything" \
	"runtime survives long enough to stop the container, reap it and clean; leak report clean"
t_2_1b() {
	need_rootfs || return
	mk_argv "$NUC_HOST" "$ROOTFS"; leak_begin
	bg_start
	if ! bg_ready; then bad "container never became ready"; evidence "$BG_ERR"; bg_stop; return; fi
	kill -INT -- "-$BG_PID"
	if wait_gone "$BG_PID" "$STOP_TIMEOUT"; then ok "runtime exited after SIGINT"; leak_end
	else bad "runtime still running ${STOP_TIMEOUT}s after SIGINT"; fi
	bg_stop
}

reg 2.3 2 "the container exits while its children are still running (teardown race)" \
	"PID 1 dies, the kernel kills the rest asynchronously, rmdir on the cgroup can hit EBUSY and is ignored" \
	"0 leaked cgroups in all iterations (set LEAK_ITER to run more)"
t_2_3() {
	need_rootfs || return
	mk_argv "$NUC_HOST" "$ROOTFS"
	local i leaked=0
	for ((i = 1; i <= ITER; i++)); do
		run_nuc $'sleep 300 &\nsleep 300 &\nsleep 300 &\nexit\n'
		sleep 0.3
		if compgen -G "$CG_ROOT/nuc-*" >/dev/null; then leaked=$((leaked + 1)); do_clean quiet; fi
	done
	if (( leaked > 0 )); then bad "cgroup left behind in $leaked of $ITER runs (rmdir raced with dying processes)"
	else ok "0 of $ITER runs left a cgroup behind"; fi
}

reg 2.4 2 "kill -9 on the runtime: no container process survives" \
	"if the runtime dies, the container must not become an orphan running forever inside its cgroup" \
	"no process left in any nuc-* cgroup 3 seconds after the runtime is killed"
t_2_4() {
	need_rootfs || return
	mk_argv "$NUC_HOST" "$ROOTFS"
	bg_start
	if ! bg_ready; then bad "container never became ready"; evidence "$BG_ERR"; bg_stop; return; fi
	kill -KILL "$BG_PID"
	sleep 3
	nuc_procs >"$T/orphans"
	if [[ -s $T/orphans ]]; then bad "container process still alive after the runtime was killed"; evidence "$T/orphans"
	else ok "container died with its runtime"; fi
	note "the cgroup directory itself may remain until you add state-based recovery (roadmap 1.2/2.4); 'make clean-leaks' removes it"
	bg_stop
}

reg 2.5 2 "Ctrl-C typed in a real terminal only interrupts the job inside the container" \
	"without a pty the container shares your terminal, so ^C also hits the runtime" \
	"the runtime survives ^C, exits 0 and cleans up; the output shows the shell still answering"
t_2_5() {
	need_tool script util-linux-script || return
	need_rootfs || return
	mk_argv "$NUC_HOST" "$ROOTFS"; leak_begin
	local cmd rc; cmd=$(printf '%q ' "${ARGV[@]}")
	{
		sleep "$STARTUP"; printf 'sleep 30\n'
		sleep 1; printf '\003'
		sleep 1; printf 'echo ALIVE_$((1+1))\n'
		sleep 1; printf 'exit\n'
	} | timeout -k 3 "$RUN_TIMEOUT" script -qefc "$cmd" /dev/null >"$T/pty.out" 2>"$T/pty.err"
	rc=${PIPESTATUS[1]}
	if tr -d '\r' <"$T/pty.out" | grep -q '^ALIVE_2'; then ok "the shell kept answering after ^C"; else bad "shell did not answer after ^C"; fi
	if (( rc == 0 )); then ok "runtime exited 0"; else bad "runtime exit status $rc (130 = killed by the ^C itself)"; fi
	leak_end
}

reg 2.6 2 "bad command lines are rejected (unknown flag, flag without value)" \
	"the parser silently ignores them, so typos start a container with the wrong settings" \
	"each bad invocation exits non-zero with a message and starts nothing"
t_2_6() {
	need_rootfs || return
	local name args n
	local -a cases=("unknown flag --bogus|--bogus -fs $ROOTFS" "-h without a value|-fs $ROOTFS -h")
	for n in "${cases[@]}"; do
		name=${n%%|*}; args=${n#*|}
		ARGV=("$NUC_BIN")
		# shellcheck disable=SC2206
		ARGV+=($args)
		run_nuc ""
		if (( RC == 0 )); then bad "$name: accepted and ran the container"; else ok "$name: rejected (exit $RC)"; fi
	done
}

# ---------------------------------------------------------------- phase 3
reg 3.0 3 "cgroup limits are really applied and enforced (guard rail)" \
	"proves the files were written AND that the kernel enforces them" \
	"memory.max, pids.max, cpu.max set; 200 forks inside hit the pids limit (passes today, keep it)"
t_3_0() {
	need_rootfs || return
	mk_argv "$NUC_HOST" "$ROOTFS"
	bg_start
	if ! bg_ready; then bad "container never became ready"; evidence "$BG_ERR"; bg_stop; return; fi
	local d v
	d=$(find "$CG_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'nuc-*' 2>/dev/null | head -n1)
	if [[ -z $d ]]; then bad "no nuc-* cgroup exists while the container runs"
	else
		v=$(cat "$d/memory.max" 2>/dev/null);      [[ -n $v && $v != max ]] && ok "memory.max = $v" || bad "memory.max is '$v'"
		v=$(cat "$d/pids.max" 2>/dev/null);        [[ -n $v && $v != max ]] && ok "pids.max = $v" || bad "pids.max is '$v'"
		v=$(cat "$d/cpu.max" 2>/dev/null);         [[ -n $v && $v != max* ]] && ok "cpu.max = $v" || bad "cpu.max is '$v'"
		v=$(cat "$d/memory.swap.max" 2>/dev/null); [[ $v == 0 ]] && ok "memory.swap.max = 0" || bad "memory.swap.max is '$v'"
	fi
	bg_send "$PROBE_PIDS"
	wait_text "$BG_OUT" DONE_SPAWN 15 || note "spawn loop did not finish in time"
	if grep -qi 'fork' "$BG_ERR"; then ok "forking beyond the limit was refused by the kernel"; else bad "200 forks all succeeded: pids limit not enforced"; fi
	bg_send 'exit'
	bg_stop
}

reg 3.2 3 "the parent cgroup survives a run" \
	"each run deletes /sys/fs/cgroup/nucleus, which races with a second container starting" \
	"the parent directory still exists after the container exits"
t_3_2() {
	need_rootfs || return
	mk_argv "$NUC_HOST" "$ROOTFS"
	run_nuc $'exit\n'
	if [[ -d $CG_ROOT ]]; then ok "$CG_ROOT still exists"; else bad "$CG_ROOT was deleted by the run"; fi
}

reg 3.3 3 "an OOM kill is reported to you" \
	"the kernel kills the process and you only see 'Killed' (or exit 137) with no idea why" \
	"runtime mentions the memory limit / oom kill after the run (reads memory.events)"
t_3_3() {
	need_rootfs || return
	local a
	for a in "$ROOTFS/usr/bin/awk" "$ROOTFS/bin/awk"; do [[ -e $a || -L $a ]] && break; a=; done
	[[ -n $a ]] || { skip "rootfs has no awk (this test allocates memory with awk)"; return; }
	mk_argv "$NUC_HOST" "$ROOTFS"
	run_nuc "$PROBE_OOM"
	if grep -q SURVIVED "$OUT"; then bad "awk allocated more than the memory limit: limit not enforced"; return; fi
	ok "the kernel killed the memory hog"
	if cat "$OUT" "$ERR" | grep -qiE 'oom|out of memory|memory limit'; then ok "the runtime told you about it"
	else bad "nothing told you the container hit its memory limit"; evidence "$ERR" 3; fi
}

reg 3.5 3 "dead code removed: cleanup_cgroup()" \
	"two cleanup paths for the same thing means the next bug fix lands in the wrong one" \
	"cleanup_cgroup is either gone or actually called"
t_3_5() {
	local n
	n=$(grep -rw cleanup_cgroup --include='*.c' --include='*.h' "$SRC_DIR" 2>/dev/null | wc -l)
	if (( n == 0 )); then ok "cleanup_cgroup no longer exists"
	elif (( n <= 2 )); then bad "cleanup_cgroup is defined and declared but never called"
	else ok "cleanup_cgroup is used"; fi
}

# ---------------------------------------------------------------- phase 4
reg 4.1 4 "pivot_root without creating an olddir inside your rootfs" \
	"creating /olddir writes into the host's rootfs and a crash leaves it behind" \
	"strace shows pivot_root(\".\", \".\")"
t_4_1() {
	need_tool strace strace || return
	need_rootfs || return
	mk_argv "$NUC_HOST" "$ROOTFS"
	run_maybe_traced pivot_root "$T/s41.log" $'exit\n'
	local a
	a=$(sed -nE 's/.*pivot_root\("([^"]*)", "([^"]*)"\).*/\1|\2/p' "$T/s41.log" | head -n1)
	if [[ -z $a ]]; then bad "no pivot_root call seen"; evidence "$ERR" 2
	elif [[ ${a%%|*} == "${a##*|}" ]]; then ok "pivot_root(new, new): no put_old directory needed"
	else bad "pivot_root(${a%%|*}, ${a##*|}): needs a put_old directory inside the rootfs"; fi
}

reg 4.2 4 "/proc is hardened (no writable /proc/sys, sysrq-trigger, kcore)" \
	"container root is host root; writable /proc/sys is a classic escape" \
	"/proc/sys and /proc/sysrq-trigger read-only, /proc/kcore masked"
t_4_2() {
	need_rootfs || return
	mk_argv "$NUC_HOST" "$ROOTFS"
	run_nuc "$PROBE_PROC"
	[[ $(pval procsys) == readonly ]] && ok "/proc/sys read-only" || bad "/proc/sys is writable from inside the container"
	[[ $(pval sysrq) == readonly ]] && ok "/proc/sysrq-trigger read-only" || bad "/proc/sysrq-trigger is writable"
	[[ $(pval kcore) == masked ]] && ok "/proc/kcore masked" || bad "/proc/kcore exposes host memory"
}

reg 4.3 4 "a usable /dev, /tmp (and /sys) exists inside the container" \
	"programs expect /dev/null, /dev/urandom, a pty directory and a writable /tmp" \
	"every device and directory reported ok"
t_4_3() {
	need_rootfs || return
	mk_argv "$NUC_HOST" "$ROOTFS"
	run_nuc "$PROBE_DEV"
	local k missing=0
	for k in dev_null dev_zero dev_urandom dev_random dev_tty dev_full dev_pts dev_shm tmp; do
		if [[ $(pval "$k") == ok ]]; then ok "$k"; else bad "$k is missing"; missing=1; fi
	done
	[[ $(pval sys) == ok ]] && ok "/sys present" || note "/sys is not mounted (Docker mounts it read-only)"
	(( missing )) && note "your probe run may also have created files in $ROOTFS/dev: check with ls -la"
}

reg 4.4 4 "writes inside the container never reach your rootfs directory" \
	"every container modifies the one shared image directory (this is what overlayfs solves in the images phase)" \
	"rootfs unchanged after a container wrote a file (DEFERRED: skipped in full runs; run it by id)" 1
t_4_4() {
	need_rootfs || return
	mk_argv "$NUC_HOST" "$ROOTFS"
	run_nuc $'echo hello > /leakcheck-probe\nexit\n'
	if [[ -e $ROOTFS/leakcheck-probe ]]; then bad "the file written inside the container now exists in $ROOTFS"; rm -f "$ROOTFS/leakcheck-probe"
	else ok "rootfs untouched"; fi
}

reg 4.5 4 "the host environment does not leak into the container" \
	"execlp() passes your whole environment (tokens, SSH_AUTH_SOCK...) into the container" \
	"a secret exported on the host is absent inside"
t_4_5() {
	need_rootfs || return
	mk_argv "$NUC_HOST" "$ROOTFS"
	run_nuc "$PROBE_ENV" LEAKCHECK_SECRET=topsecret
	if [[ $(pval secret) == absent ]]; then ok "host variable not visible inside"; else bad "LEAKCHECK_SECRET leaked into the container"; fi
}

# ---------------------------------------------------------------- phase 5
host_online() { have ping && ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; }

reg 5.1 5 "two containers at the same time" \
	"fixed veth/IP names make the second container fail; Docker uses a bridge, unique names and an IP pool" \
	"both run, both exit 0, two cgroups existed at once, leak report clean"
t_5_1() {
	need_rootfs || return
	mk_argv "$NUC_HOST" "$ROOTFS"; leak_begin
	local pa pb ra rb n
	printf 'sleep 4\nexit\n' | timeout -k 3 "$RUN_TIMEOUT" "${ARGV[@]}" >"$T/ca.out" 2>"$T/ca.err" & pa=$!
	sleep 0.5
	printf 'sleep 4\nexit\n' | timeout -k 3 "$RUN_TIMEOUT" "${ARGV[@]}" >"$T/cb.out" 2>"$T/cb.err" & pb=$!
	sleep 2.5
	n=$(find "$CG_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'nuc-*' 2>/dev/null | wc -l)
	wait "$pa"; ra=$?; wait "$pb"; rb=$?
	(( n == 2 )) && ok "two cgroups existed at the same time" || bad "saw $n container cgroup(s) while two were running"
	if (( ra == 0 )); then ok "first container exited 0"; else bad "first container exit $ra"; evidence "$T/ca.err" 2; fi
	if (( rb == 0 )); then ok "second container exited 0"; else bad "second container exit $rb"; evidence "$T/cb.err" 2; fi
	scan_sanitizer "$T/ca.err"; scan_sanitizer "$T/cb.err"
	leak_end
}

reg 5.2 5 "container subnet is private address space" \
	"12.x.x.x belongs to a real organisation, so containers could never reach those real addresses" \
	"every IP literal in the source is 10/8, 172.16/12, 192.168/16 or loopback"
t_5_2() {
	local ip a b bad_n=0 ips
	ips=$(grep -hoE '\b[0-9]{1,3}(\.[0-9]{1,3}){3}\b' "$SRC_DIR"/*.c "$SRC_DIR"/*.h 2>/dev/null | sort -u)
	[[ -n $ips ]] || { skip "no IP address literals found in $SRC_DIR"; return; }
	for ip in $ips; do
		IFS=. read -r a b _ _ <<<"$ip"
		if (( a == 10 || a == 127 || a == 0 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168) )); then ok "$ip is private"
		else bad "$ip is public address space"; bad_n=1; fi
	done
}

reg 5.3a 5 "no hard-coded host network interface name" \
	"-o enp2s0 only works on your desktop; Docker's rule uses '! -o <bridge>' instead" \
	"no enp/eno/ens/eth/wlp names in the source"
t_5_3a() {
	if grep -nE '\b(enp|eno|ens|eth[0-9]|wlp|wlan[0-9])[0-9a-z]*\b' "$SRC_DIR"/*.c >"$T/nic" 2>/dev/null; then bad "hard-coded interface name"; evidence "$T/nic" 3
	else ok "no hard-coded interface names"; fi
}

reg 5.3b 5 "the NAT rule is added once per container and removed afterwards" \
	"-A without a check appends a duplicate on every run, and nothing ever deletes it" \
	"after two runs: no iptables_nat / iptables_dups leaks"
t_5_3b() {
	need_tool iptables iptables-nft || return
	need_rootfs || return
	mk_argv "$NUC_HOST" "$ROOTFS"; leak_begin
	run_nuc $'exit\n'; run_nuc $'exit\n'
	leak_end
}

reg 5.3c 5 "ip_forward is restored to what it was" \
	"enabling forwarding is a global change on your machine; it needs an owner that undoes it" \
	"ip_forward is 0 again after a run that started with 0"
t_5_3c() {
	need_rootfs || return
	set_ipf 0
	mk_argv "$NUC_HOST" "$ROOTFS"
	run_nuc $'exit\n'
	local v; v=$(cat /proc/sys/net/ipv4/ip_forward)
	if [[ $v == 0 ]]; then ok "ip_forward restored to 0"; else bad "ip_forward is $v after the run (it was 0)"; fi
	set_ipf "$ORIG_IPF"; IPF_CHANGED=
}

reg 5.5a 5 "the container can reach the internet by IP (NAT works)" \
	"proves veth + routing + MASQUERADE + forwarding end to end" \
	"ping 1.1.1.1 works from inside"
t_5_5a() {
	need_rootfs || return
	host_online || { skip "the host itself cannot ping 1.1.1.1"; return; }
	mk_argv "$NUC_HOST" "$ROOTFS"
	run_nuc "$PROBE_NAT"
	if [[ $(pval nat) == ok ]]; then ok "1.1.1.1 reachable"; else bad "no route out (check: ip_forward, NAT rule, firewalld on Fedora)"; fi
}

reg 5.5b 5 "DNS works inside the container" \
	"the host's resolv.conf may point at 127.0.0.53, which does not exist in another network namespace" \
	"nameserver is a reachable address and example.com resolves"
t_5_5b() {
	need_rootfs || return
	host_online || { skip "the host itself cannot ping 1.1.1.1"; return; }
	mk_argv "$NUC_HOST" "$ROOTFS"
	run_nuc "$PROBE_DNS"
	local r; r=$(pval resolv)
	[[ -z $r ]] && bad "no nameserver configured in the container" || ok "resolv.conf: $r"
	[[ $r == *127.0.0.* ]] && bad "nameserver points at loopback (unreachable from the container)"
	if [[ $(pval dns) == ok ]]; then ok "example.com resolves and answers"; else bad "name resolution failed"; fi
}

# ====================================================================
#                              COMMANDS
# ====================================================================
preflight() { # [needs_bin]
	[[ $EUID -eq 0 ]] || die "run as root (make does this with sudo)"
	if [[ -z ${LEAK_NO_PREFLIGHT:-} ]] && [[ $(stat -f -c %T /sys/fs/cgroup 2>/dev/null) != cgroup2fs ]]; then
		die "/sys/fs/cgroup is not cgroup v2: Nucleus needs the unified hierarchy"
	fi
	if [[ ${1:-} == bin ]]; then
		[[ -x $NUC_BIN ]] || die "$NUC_BIN not found - run: make build"
	fi
}

cmd_check() {
	[[ ${1:-} == -- ]] && shift
	(( $# )) || die "usage: leakcheck.sh check -- <command> [args...]"
	preflight
	snapshot "$T/before"
	echo "${BOLD}>>> running: $*${OFF}"
	"$@"
	local rc=$?
	echo "${BOLD}>>> container exited with status $rc${OFF}"
	sleep "$SETTLE"
	snapshot "$T/after"
	compare "$T/before" "$T/after" full
	echo
	echo "${BOLD}=========== LEAK REPORT ===========${OFF}"
	printf '%s' "$REPORT"
	echo "==================================="
	if (( DIRTY_N == 0 )); then echo "${GREEN}${BOLD}CLEAN${OFF}: nothing left behind."; exit 0; fi
	echo "${RED}${BOLD}DIRTY${OFF}: items marked [LEAK] survived the run."
	echo "run ./leakcheck.sh explain <id> for any roadmap id shown, or 'make clean-leaks' to reset."
	exit 1
}

cmd_list() {
	local id
	printf '%-6s %-6s %s\n' ID PHASE TITLE
	for id in "${ORDER[@]}"; do
		printf '%-6s %-6s %s%s\n' "$id" "${T_PHASE[$id]}" "${T_TITLE[$id]}" "$([[ ${T_DEFER[$id]} == 1 ]] && echo '  (deferred)')"
	done
}

cmd_explain() {
	local id=${1:-}
	[[ -n $id && -n ${T_TITLE[$id]:-} ]] || die "unknown test id '$id' (see: leakcheck.sh list)"
	echo "${BOLD}$id  ${T_TITLE[$id]}${OFF}"
	echo "why it matters : ${T_WHY[$id]}"
	echo "fixed when     : ${T_FIXED[$id]}"
	echo "run it         : make test T=$id"
	echo "details        : ROADMAP.md, section $id"
}

PASSED=0; SKIPPED=0; FAILED=()
run_test() {
	local id=$1 st m
	R_FAIL=0; R_SKIP=0; MSGS=(); SAN_HIT=0; SAN_TEXT=""; TRACED=0
	do_clean quiet
	"t_${id//./_}"
	if (( SAN_HIT )); then bad "the sanitizer reported an error in the runtime:"; evidence_text "$SAN_TEXT"; fi
	if (( R_FAIL )); then st="${RED}FAIL${OFF}"; FAILED+=("$id")
	elif (( R_SKIP )); then st="${YELLOW}SKIP${OFF}"; SKIPPED=$((SKIPPED + 1))
	else st="${GREEN}PASS${OFF}"; PASSED=$((PASSED + 1)); fi
	printf '[%s] %-5s %s\n' "$st" "$id" "${T_TITLE[$id]}"
	for m in "${MSGS[@]}"; do printf '          %s\n' "$m"; done
	if (( R_FAIL )); then
		printf '          %swhy:%s   %s\n' "$BOLD" "$OFF" "${T_WHY[$id]}"
		printf '          %sfixed:%s %s\n' "$BOLD" "$OFF" "${T_FIXED[$id]}"
		printf '          %ssee ROADMAP.md section %s%s\n' "$DIM" "$id" "$OFF"
	fi
}

cmd_test() {
	local want=() w id pick include deferred=0
	for w in "$@"; do
		case $w in
			--deferred) deferred=1 ;;
			*) want+=("$w") ;;
		esac
	done
	for w in "${want[@]}"; do
		[[ $w == all || $w =~ ^[0-9]$ || -n ${T_TITLE[$w]:-} ]] || die "unknown test or phase '$w' (see: leakcheck.sh list)"
	done
	preflight bin
	echo "${BOLD}Nucleus test suite${OFF}  binary=$NUC_BIN  rootfs=${ROOTFS:-<unset>}"
	echo "${DIM}starting from a clean host (removing leftovers of earlier crashed runs)${OFF}"
	do_clean quiet
	echo
	for id in "${ORDER[@]}"; do
		include=0
		if (( ${#want[@]} == 0 )); then
			[[ ${T_DEFER[$id]} == 0 || $deferred == 1 ]] && include=1
		else
			for w in "${want[@]}"; do
				if [[ $w == all && ( ${T_DEFER[$id]} == 0 || $deferred == 1 ) ]] || [[ $w == "$id" || $w == "${T_PHASE[$id]}" ]]; then include=1; fi
			done
		fi
		(( include )) && run_test "$id"
	done
	do_clean quiet
	echo
	echo "${BOLD}passed ${PASSED}   failed ${#FAILED[@]}   skipped ${SKIPPED}${OFF}"
	if (( ${#FAILED[@]} )); then
		echo "failing: ${FAILED[*]}"
		echo "next in roadmap order: ${BOLD}${FAILED[0]}${OFF}   ->  ./leakcheck.sh explain ${FAILED[0]}"
		exit 1
	fi
	echo "${GREEN}${BOLD}ALL GOOD${OFF}"
}

rd() { cat "$1" 2>/dev/null || echo '?'; }
cmd_status() {
	local d n found=0
	echo "${BOLD}== cgroups under $CG_ROOT${OFF}"
	for d in "$CG_ROOT"/nuc-*; do
		[[ -d $d ]] || continue
		found=1
		printf '  %s  procs=%s  mem=%s/%s  pids=%s/%s  cpu="%s"  oom_kill=%s\n' "$(basename "$d")" \
			"$(wc -l <"$d/cgroup.procs" 2>/dev/null)" "$(rd "$d/memory.current")" "$(rd "$d/memory.max")" \
			"$(rd "$d/pids.current")" "$(rd "$d/pids.max")" "$(rd "$d/cpu.max")" \
			"$(awk '/^oom_kill /{print $2}' "$d/memory.events" 2>/dev/null)"
	done
	(( found )) || echo "  (none)"
	echo "${BOLD}== network interfaces matching $LINK_REGEX${OFF}"
	if have ip; then ip -o link show | awk '{print $2}' | sed 's/[@:].*//' | grep -E "$LINK_REGEX|^nuc" | sed 's/^/  /' | sort -u; else echo "  (ip not installed)"; fi
	echo "${BOLD}== NAT rules${OFF}"
	if have iptables; then iptables -t nat -S POSTROUTING 2>&1 | grep -E 'MASQUERADE' | sed 's/^/  /'; else echo "  (iptables not installed)"; fi
	echo "${BOLD}== ip_forward${OFF}  $(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)"
	echo "${BOLD}== processes inside nuc-* cgroups${OFF}"
	nuc_procs | sed 's/^/  /'
}

cmd_help() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; }

case ${1:-help} in
	--) cmd_check "$@" ;;
	check) shift; cmd_check "$@" ;;
	test) shift; cmd_test "$@" ;;
	list) cmd_list ;;
	explain) shift; cmd_explain "${1:-}" ;;
	status) cmd_status ;;
	clean) preflight; do_clean; echo "clean done." ;;
	help|-h|--help) cmd_help ;;
	*) die "unknown command '$1' (try: leakcheck.sh help)" ;;
esac