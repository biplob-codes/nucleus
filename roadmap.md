# Nucleus roadmap: make the existing features correct first

Every task id below is also a test id: `make test T=<id>` runs it, `make explain T=<id>` explains it.

## How to work with this file

1. `make test` and read the first `FAIL`. The suite prints failures in roadmap order, and the last line says which one to do next.
2. Read that task here. Fix it. Run `make test T=<id>`; when it says `PASS`, run `make test` again to see you broke nothing.
3. `make run` is unchanged. `make check` is the quick leak report. `make status` (or `make watch` in a second terminal while `make run` is open) shows what Nucleus owns on the host right now, so you can _see_ cgroups, veths and NAT rules appear and disappear.
4. If a crash leaves junk behind: `make clean-leaks`.

What a result means:

- `[LEAK] name -> ... (roadmap x.y)`: the host differs before/after your run. `appeared:` lines are things your run created and never removed; `disappeared:` lines are things it removed that it shouldn't have. The roadmap ids tell you which tasks fix it.
- `[FAIL]` on a behaviour test: the lines starting with `✗` are the evidence, `why:` is the reason and `fixed:` is the exact condition for PASS.
- `PASS` on a task means the host looks the way this file says it should. It is not a proof of correctness, only of this behaviour.
- Tests marked _guard rail_ pass today. They exist so a refactor cannot silently break them.

Things the suite does on purpose, so you are not surprised: it temporarily sets `ip_forward` to 0 for two tests and restores it, it injects failures with fake `ip`/`iptables` programs placed in the container's PATH only, and it deletes anything named `nuc-*` (cgroups, veths) plus MASQUERADE rules for `NUC_SUBNETS` (default `12.200.1.0/24`). When you change your subnet in task 5.2, run with `NUC_SUBNETS="your.new/24"` or edit the default at the top of `leakcheck.sh`.

Optional tools: `strace` (tasks 1.1, 1.4, 4.1 get stronger proofs) and `script` (task 2.5). Missing ones are reported as SKIP with the package name.

When you change the command line in 2.6, edit `mk_argv` at the top of `leakcheck.sh`; it is the only place that knows the CLI shape.

---

## Phase 0: tests (done: this is `leakcheck.sh`)

- **0.1** a plain run leaves the host exactly as it found it (what `make check` does).
- **0.2** exit status is propagated (guard rail).
- **0.4** isolation sanity: PID 1, hostname, own /proc, own network namespace (guard rail).

---

## Phase 1: the spine

Why first: every later subsystem needs an identity for the container, one owner per resource, and a defined setup and teardown order. Without them nothing can be finished, which is why every part feels like it needs another part first.

### 1.1 Two owners of one file descriptor

**Breaks:** `main` closes `conf.sync_fd[0]` and `[1]` and sets only `conf.sync_fd[0]` to -1. `ledger.sync_fd` still holds both numbers, so `clean_up` closes them again.
**Why:** `Config` and `ledger` both store the same fds. Today the second close just returns EBADF. If anything opened a file in between, that number could belong to something else and you would close it.
**Should:** one struct owns each fd; closing sets it to -1 in the same place.
**Hint:** "single source of truth"; why `close(); fd = -1;` belongs in one helper.
**Verify:** `make test T=1.1` (needs strace). Broken: `✗ N close() call(s) on an fd that was already closed` with the offending lines. Fixed: PASS, and no EBADF line.

### 1.2 No container identity

**Breaks:** everything is named after the child's host PID (`nuc-<pid>`), and the network names are fixed.
**Why:** PIDs get reused and nothing else can be unique. Docker gives each container a 64-hex ID and derives every resource name from it. runc keeps a state directory per ID (`/run/runc/<id>/`) so a crashed runtime can be cleaned up later.
**Should:** generate an ID in the parent before acquiring anything; cgroup, veth and state file names derive from it.
**Hint:** read about `runc create / start / state / delete` and why they are separate steps.
**Verify:** no direct test; it is proven by 5.1 (two at once) and 2.4 (recovery after a crash).

### 1.3 The ledger does not cover everything

**Breaks:** cgroups, fds and the stack are tracked. The veth, the NAT rule and `ip_forward` are not. `clean_up` is not safe to call twice (`free(stack)` without NULL) and ignores `rmdir` failures.
**Why:** a ledger only helps if every acquire is recorded and every release is attempted, including on the failure paths.
**Should:** each acquire adds an entry; cleanup is idempotent, runs in reverse order of acquisition and logs what it could not release.
**Hint:** cleanup stacks, and `goto cleanup` chains in the Linux kernel.
**Verify:** `make test T=1.3a` and `T=1.3b` inject failures. 1.3a makes `ip link set ... netns` fail; broken: `[LEAK] links ... appeared: nuc-vh`, because the veth pair was created but never moved. 1.3b makes `iptables` fail; broken: `[LEAK] ip_forward` (the sysctl was changed and never put back). Fixed: no `[LEAK]` lines and the runtime exits non-zero with a clear message.

### 1.4 Validate before acquiring

**Breaks:** a hostname over 64 characters only fails at `sethostname`, at the very end; a rootfs without `/bin/sh` or `/proc` only fails in the child after the cgroup and network exist.
**Why:** failing late means every earlier step has to be undone, and every undo is a chance for a leak.
**Should:** the parent checks everything it can (hostname length, rootfs usable, `realpath`) before the first resource is created.
**Hint:** "fail fast".
**Verify:** `make test T=1.4a` and `T=1.4b`. Broken: `✗ namespaces were created BEFORE ... was validated` (strace saw `clone` with `CLONE_NEW*`). Fixed: non-zero exit and no clone.

### 1.5 One error path

**Breaks:** `nuc_err_report`, `perror` and bare `return 1` are mixed. `perror` after `system()` is meaningless because `system` does not set errno. A `read()` that returns 0 is end-of-file, not an error, yet you print the stale errno ("Success"). Custom codes (1000+) stored in errno print as "Unknown error" if anything calls `perror`.
**Should:** one reporting function, with context (which path or command failed); errno is only read right after a syscall that set it.
**Hint:** return values vs errno; `strerror` is not thread-safe.
**Verify:** `make test T=1.5`. Broken: `✗ ...: misleading message` or `perror() still used`. Fixed: each bad invocation prints a clear one-line message, no `perror(` in the source.

---

## Phase 2: process lifecycle and signals

### 2.1 The runtime dies first and cleans nothing

**Breaks:** the runtime has no signal handlers. SIGTERM, or Ctrl-C (the terminal sends SIGINT to the runtime and the shell), kills the runtime on the spot. The shell keeps running; cgroup, NAT and everything else stay behind.
**Should:** the runtime handles SIGINT and SIGTERM, forwards them to the container's init, waits for the child, reaps it, runs cleanup. If the container ignores the signal (PID 1 ignores signals it has no handler for), kill it after a grace period like `docker stop` (SIGTERM, 10s, SIGKILL). Also retry `waitpid` on EINTR.
**Hint:** `sigaction`, `EINTR`, `docker run --sig-proxy`.
**Verify:** `make test T=2.1a` (SIGTERM to the runtime) and `T=2.1b` (SIGINT to the whole process group, like Ctrl-C). Broken: `✗ host is not clean afterwards: cgroups procs` and `[LEAK] procs ... a shell still alive`. Fixed: the runtime exits within `LEAK_STOP_TIMEOUT` seconds (default 15) and nothing is left.

### 2.2 PID 1 is a shell (manual)

**Breaks:** nothing automatic. PID 1 in a PID namespace ignores signals it has no handler for, and adopts orphans, which become zombies if it never calls `wait`. Docker ships `--init` (tini) for this.
**Task:** understand it and write down in your README what you chose. No test.
**Hint:** "PID 1 problem in containers".

### 2.3 Teardown races with dying processes

**Breaks:** when PID 1 exits the kernel kills the rest of the namespace asynchronously. `rmdir` on the cgroup can fail with EBUSY, and the ledger ignores it.
**Should:** kill everything in the cgroup, wait until it is empty, then remove it.
**Hint:** the cgroup v2 files `cgroup.kill` (kernel 5.14+) and `cgroup.events` (`populated 0`).
**Verify:** `make test T=2.3` runs the container 10 times with three background `sleep`s and exits immediately (`LEAK_ITER=50 make test T=2.3` for more). Broken: `✗ cgroup left behind in 3 of 10 runs`. Fixed: 0 of 10, repeatedly. It can pass by luck once, so run it a few times.

### 2.4 Runtime killed: container survives

**Breaks:** `kill -9` on the runtime leaves the shell running forever in its cgroup.
**Should:** the container dies when its parent dies, and a state file (see 1.2) lets a later command clean up what is left.
**Hint:** `PR_SET_PDEATHSIG` and its caveat with threads.
**Verify:** `make test T=2.4`. Broken: `✗ container process still alive after the runtime was killed` with the process line. Fixed: no process remains 3 seconds later. The cgroup directory may still need recovery; that is the state-file part.

### 2.5 No pty

**Breaks:** the container shares your terminal, so you get no job control and Ctrl-C hits the runtime too. Docker allocates a pty pair, the container gets the slave as stdio with `setsid` and a controlling terminal, and the runtime copies bytes between your terminal (in raw mode) and the master, forwarding `SIGWINCH`.
**Hint:** `openpty`, `setsid`, `TIOCSCTTY`, `SIGWINCH`. Do it after 2.1.
**Verify:** `make test T=2.5` (needs `script`) types Ctrl-C in a real pty. Broken: `✗ runtime exit status 130` and leaks. Fixed: the shell still answers, exit 0, clean.

### 2.6 Command line

**Breaks:** `parse` ignores unknown flags and a flag without a value, there is no way to give a command (always `/bin/sh`), and exit code 125 is ambiguous (Docker uses 125 for "the runtime failed" and 126/127 for exec errors).
**Should:** `nucleus [options] <rootfs> [-- cmd args...]` with real option parsing; `Config` carries the command.
**Hint:** `getopt_long`, and the `--` convention.
**Verify:** `make test T=2.6`. Broken: `✗ unknown flag --bogus: accepted and ran the container`. Fixed: rejected with a message. Then update `mk_argv` in `leakcheck.sh`.

---

## Phase 3: cgroups

### 3.0 Limits really apply (guard rail)

`make test T=3.0` reads `memory.max`, `pids.max`, `cpu.max` and `memory.swap.max` while a container runs, then tries to start 200 processes and expects the kernel to refuse some. It passes today; keep it passing when you make limits configurable.

### 3.1 Controller check is a substring match (manual)

**Breaks:** `strstr(buf, "cpu")` also matches `cpuset`, so a host with `cpuset` but without `cpu` passes the check and fails later with a confusing write error.
**Should:** match whole space-separated tokens.
**Hint:** split "parse" from "read the file" so you can test the parser with fixed strings. Cannot be tested from outside, which is exactly why.

### 3.2 Parent cgroup ownership race

**Breaks:** every run deletes `/sys/fs/cgroup/nucleus`. If A exits while B is between `mkdir nucleus` (EEXIST) and `mkdir nuc-<id>`, B fails. Docker and runc never delete the parent.
**Should:** the parent is persistent; only per-container cgroups are yours to remove.
**Verify:** `make test T=3.2`. Broken: `✗ /sys/fs/cgroup/nucleus was deleted by the run`. Fixed: it still exists.

### 3.3 OOM is invisible

**Breaks:** the kernel kills the memory hog and you only see "Killed".
**Should:** before removing the cgroup, read `memory.events` and report `oom_kill`, like Docker's `OOMKilled`.
**Verify:** `make test T=3.3` allocates up to 128 MB with `awk`, with a 64 MB limit, so it is safe. Broken: `✗ nothing told you the container hit its memory limit`. Fixed: the runtime says so.

### 3.4 Host assumptions (manual)

You do not check you are on cgroup v2 (`leakcheck.sh` does), and `memory.swap.max` can be missing on some kernels, which fails the whole run. Hint: `statfs`, `CGROUP2_SUPER_MAGIC`. Advanced aside: `clone3` with `CLONE_INTO_CGROUP` removes the move-after-clone step.

### 3.5 Dead code

`cleanup_cgroup` is never called. Delete it so there is one cleanup path. `make test T=3.5` goes from FAIL to PASS.

Limits are hard-coded macros; make them configurable after 2.6, once `Config` can carry them.

---

## Phase 4: filesystem

### 4.1 pivot_root without `olddir`

**Breaks:** you create `/olddir` inside the host's rootfs; a crash in between leaves it there (the leak report's `rootfs` line).
**Should:** runc's trick: `chdir(new_root); pivot_root(".", "."); umount2(".", MNT_DETACH)`. No directory is created and the rootfs is never written to.
**Hint:** the NOTES section of `pivot_root(2)`.
**Verify:** `make test T=4.1` (needs strace). Broken: `✗ pivot_root(/path, /path/olddir)`. Fixed: `pivot_root(new, new)`.

### 4.2 /proc is wide open

**Breaks:** `/proc` is mounted bare. `/proc/sys`, `/proc/sysrq-trigger` and `/proc/kcore` are reachable, and container root is host root (no user namespace, no capability drop). Writing `/proc/sys/kernel/core_pattern` is a classic escape. Docker mounts these read-only or masks them with `/dev/null` (OCI `readonlyPaths` and `maskedPaths`).
**Should:** do this together with your capabilities task.
**Verify:** `make test T=4.2`. Broken: `✗ /proc/sys is writable from inside the container`. Fixed: read-only, masked.

### 4.3 No /dev, /tmp, /sys

**Breaks:** the container gets whatever your Alpine tarball happens to contain. runc mounts a tmpfs on `/dev` and bind-mounts or creates the standard devices.
**Hint:** OCI runtime spec, "default devices"; you need devpts for 2.5.
**Verify:** `make test T=4.3` lists each device. Each missing one is a separate `✗`. Fixed: all `✓`.

### 4.4 Writes reach your rootfs (deferred to the images phase)

Every container modifies the one shared directory. This is what overlayfs solves later. `make test T=4.4` shows it; it is skipped in the normal full run.

### 4.5 Environment leak

**Breaks:** `execlp` passes the host environment (with `sudo`, most of it) into the container. Docker builds an explicit one (PATH, HOME, HOSTNAME, TERM). Also set a working directory and umask.
**Verify:** `make test T=4.5` exports a secret on the host. Broken: `✗ LEAKCHECK_SECRET leaked into the container`. Fixed: absent.

---

## Phase 5: networking (biggest redesign)

### 5.1 One container at a time

**Breaks:** the host veth is always `nuc-vh` and the IPs are fixed. A second container fails at `ip link add`. Docker creates a bridge (`docker0`) once, attaches each container's veth to it with a unique name, and allocates an IP from a pool (IPAM).
**Hint:** Linux bridges, `ip link set X master Y`.
**Verify:** `make test T=5.1` starts two containers 0.5s apart. Broken: `✗ second container exit 1` plus its error line. Fixed: both exit 0, two cgroups existed at once, host clean. If you keep a persistent bridge named `nuc0`, it does not match the default `LINK_REGEX` (`^nuc-`), but the leak report will show it appearing; allow it with `LEAK_ALLOW_LINKS='^nuc0$'`.

### 5.2 Public subnet

`12.200.1.0/24` is real public address space, so containers can never reach those real addresses. Docker uses RFC 1918 space. `make test T=5.2` scans every IP literal in your source. Fixed: all private.

### 5.3 NAT rule and ip_forward ownership

**Breaks:** `-A` is appended on every run and never deleted, and the rule hard-codes `-o enp2s0`, your desktop's NIC. `ip_forward` is turned on and never restored. Docker's rule uses `! -o <bridge>` and does not name a physical interface.
**Should:** the rule goes in the ledger, is added only if missing (`-C`), deleted on cleanup. Record the old `ip_forward`. With a shared bridge you need a reference count.
**Verify:** `make test T=5.3a` (no NIC names in source), `T=5.3b` (two runs, then `[LEAK] iptables_nat` or `iptables_dups` when broken), `T=5.3c` (`ip_forward` restored). Fixed: all PASS.

### 5.4 Partial failure

Covered by 1.3a: if setup fails after `ip link add`, the pair stays in the host namespace. When the container's namespace dies the peer disappears with it, but only if it was already moved in.

### 5.5 NAT and DNS inside

**Breaks:** even with NAT working, DNS will not: Fedora's resolver is systemd-resolved, so the host's `/etc/resolv.conf` points at `127.0.0.53`, which does not exist in another network namespace. Docker generates the container's `resolv.conf`. Also, firewalld on Fedora may block forwarded traffic; check the zone of your bridge if packets leave but replies do not return.
**Verify:** `make test T=5.5a` pings `1.1.1.1` (NAT), `T=5.5b` resolves `example.com`. Both are skipped if the host itself is offline. Broken: `✗ no route out` or `✗ nameserver points at loopback`.

### 5.6 `system("ip ...")` (stretch)

Shelling out is a fine first stage. The real bugs are the naming, cleanup and error handling above. Docker's libnetwork talks netlink directly; treat that as optional.

### 5.7 Network mode (later)

Docker has `--network none`. Once `Config` exists, networking should be a choice.

---

## After this

Only then: the IPC namespace (one missing flag; Docker unshares it by default), capabilities and `no_new_privs`, seccomp, user namespaces, the images phase (overlayfs). "Done" for the foundation means `make test` ends with `ALL GOOD`, including the crash, signal and two-container tests.
