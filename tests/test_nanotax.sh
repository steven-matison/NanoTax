#!/usr/bin/env bash
# Contract tests for nanotax. No Jetson, Hailo, or CUDA required.
# A failure here means the script broke a promise in the header or the README:
# workers die with the process, a signal aborts the run, missing sensors are
# omitted, and a GPU-off run does not claim a TensorRT flood.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NT="$ROOT/nanotax"
PASS=0
FAIL=0
KEEP=()

say() { printf '%s\n' "$*"; }
ok() { PASS=$((PASS + 1)); say "PASS  $1"; }
fail() { FAIL=$((FAIL + 1)); say "FAIL  $1"; [[ -n ${2:-} ]] && say "      $2"; }

# Every nanotax this suite starts. Spinner helpers only look at awk workers
# whose parent is one of these, or that were orphaned (reparented to pid 1),
# so a nanotax running in another terminal is neither counted nor killed.
NT_PIDS=()

spinners() {
  local pid cmd ppid p
  for pid in $(pgrep -u "$(id -u)" -x awk 2>/dev/null || true); do
    cmd="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)"
    [[ $cmd == *1.0000001* ]] || continue
    ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    [[ $ppid == 1 ]] && { echo "$pid"; continue; }
    for p in "${NT_PIDS[@]:-}"; do
      [[ $ppid == "$p" ]] && { echo "$pid"; break; }
    done
  done
}

reap_spinners() {
  local pid
  for pid in $(spinners); do
    kill -KILL "$pid" 2>/dev/null || true
  done
}
trap reap_spinners EXIT

spinner_count() { spinners | wc -l; }

tmp_dirs() {
  find /tmp -maxdepth 1 -name 'nanotax.*' -user "$(id -u)" 2>/dev/null | sort
}

# Kill a nanotax we started with setsid, and not this test's process group.
kill_nt_group() {
  local pid=$1 pgid my
  my="$(ps -o pgid= -p "$$" | tr -d ' ')"
  pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  if [[ -n $pgid && $pgid != "$my" ]]; then
    kill -KILL -- "-$pgid" 2>/dev/null || true
  else
    kill -KILL "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
  reap_spinners
}

# Wait until $pid exits. Returns 0 if it did, 1 if it had to be killed.
wait_or_kill() {
  local pid=$1 tries=${2:-10} i
  for ((i = 0; i < tries; i++)); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.2
  done
  kill_nt_group "$pid"
  return 1
}

# Starts nanotax in this shell so the test can wait on it. Sets NT_PID and NT_LOG.
start_nt() {
  NT_LOG="$(mktemp)"
  KEEP+=("$NT_LOG")
  # Own session, so killing its process group cannot hit this test.
  setsid env NANOTAX_GPU=off NANOTAX_COLOR=never "$NT" "$@" >"$NT_LOG" 2>&1 &
  NT_PID=$!
  NT_PIDS+=("$NT_PID")
}

# Block until $log mentions $phase or $pid is gone. Returns 0 on the phase.
wait_for_phase() {
  local pid=$1 log=$2 phase=$3 deadline=$((SECONDS + ${4:-15}))
  while (( SECONDS < deadline )); do
    grep -q "$phase" "$log" && return 0
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
  done
  return 1
}

# ── syntax and flags ───────────────────────────────────────────────────────
if bash -n "$NT" && bash -n "$ROOT/install.sh"; then
  ok "bash -n nanotax install.sh"
else
  fail "bash -n nanotax install.sh"
fi

ver="$("$NT" --version 2>&1 || true)"
[[ $ver == "nanotax 1.0.0" ]] && ok "--version prints nanotax 1.0.0" \
  || fail "--version" "got: $ver"

before="$(tmp_dirs)"
"$NT" --version >/dev/null
after="$(tmp_dirs)"
[[ $before == "$after" ]] && ok "--version creates no /tmp/nanotax.* dir" \
  || fail "--version creates no /tmp/nanotax.* dir"

"$NT" --help >/dev/null && ok "--help exits 0" || fail "--help exits 0"
help="$("$NT" --help 2>&1 || true)"
[[ $help == *NANOTAX_GPU* && $help == *NANOTAX_HEF* ]] \
  && ok "--help lists the environment knobs" \
  || fail "--help lists the environment knobs"

"$NT" --nope >/dev/null 2>&1
rc=$?
[[ $rc -eq 2 ]] && ok "unknown argument exits 2" || fail "unknown argument exits 2" "exit $rc"

# ── loader ─────────────────────────────────────────────────────────────────
log="$(mktemp)"; KEEP+=("$log")
NANOTAX_GPU=off NANOTAX_COLOR=never "$NT" --loader >"$log" 2>&1
rc=$?
[[ $rc -eq 0 ]] && ok "--loader exits 0" || fail "--loader exits 0" "exit $rc"
grep -q "INVENTORY" "$log" && ok "--loader prints the inventory" \
  || fail "--loader prints the inventory"
if grep -q $'\e' "$log"; then
  fail "--loader with NANOTAX_COLOR=never has no ANSI"
else
  ok "--loader with NANOTAX_COLOR=never has no ANSI"
fi
[[ $(spinner_count) -eq 0 ]] && ok "--loader starts no CPU storm" \
  || fail "--loader starts no CPU storm" "$(spinner_count) awk spinners still running"
[[ $(tmp_dirs) == "$before" ]] && ok "--loader removes its temp dir" \
  || fail "--loader removes its temp dir"

# The header promises nothing is written outside the mktemp dir. HailoRT, for
# one, drops a hailort.log wherever it is imported from, so run from an empty
# directory and insist it stays empty.
cwd="$(mktemp -d)"; KEEP+=("$cwd")
(cd "$cwd" && NANOTAX_GPU=off NANOTAX_COLOR=never "$NT" --loader >/dev/null 2>&1)
stray="$(ls -A "$cwd")"
[[ -z $stray ]] && ok "--loader writes nothing to the current directory" \
  || fail "--loader writes nothing to the current directory" "left behind: $stray"

# ── install.sh copies the local script and does not curl ──────────────────
fake="$(mktemp -d)"; KEEP+=("$fake")
mkdir -p "$fake/bin" "$fake/prefix"
printf '%s\n' '#!/bin/sh' 'echo curl-called >>"'"$fake"'/curl.log"' 'exit 99' >"$fake/bin/curl"
chmod +x "$fake/bin/curl"
if PATH="$fake/bin:$PATH" PREFIX="$fake/prefix" bash "$ROOT/install.sh" >"$fake/install.out" 2>&1; then
  ok "install.sh exits 0 with a local nanotax"
else
  fail "install.sh exits 0 with a local nanotax" "$(cat "$fake/install.out")"
fi
[[ ! -e $fake/curl.log ]] && ok "install.sh does not download when the script is beside it" \
  || fail "install.sh does not download when the script is beside it"
cmp -s "$NT" "$fake/prefix/nanotax" && ok "install.sh installs this tree's nanotax, unchanged" \
  || fail "install.sh installs this tree's nanotax, unchanged"
got="$("$fake/prefix/nanotax" --version 2>&1 || true)"
[[ $got == "nanotax 1.0.0" ]] && ok "installed copy runs --version" \
  || fail "installed copy runs --version" "$got"

# ── mktemp failure is fatal ────────────────────────────────────────────────
# With WORK empty the script would go on to write "$WORK/flood.py", i.e.
# /flood.py. Aborting on a failed mktemp is the whole contract here.
fake2="$(mktemp -d)"; KEEP+=("$fake2")
printf '%s\n' '#!/bin/sh' 'echo mktemp-disabled >&2' 'exit 1' >"$fake2/mktemp"
chmod +x "$fake2/mktemp"
PATH="$fake2:$PATH" NANOTAX_GPU=off "$NT" --loader >"$fake2/out" 2>"$fake2/err"
rc=$?
[[ $rc -ne 0 ]] && ok "mktemp failure aborts the run" \
  || fail "mktemp failure aborts the run" "exit $rc; a failed mktemp is ignored and the run continues"
if grep -q "INVENTORY" "$fake2/out"; then
  fail "mktemp failure stops before the inventory" "the run continued with an empty WORK"
else
  ok "mktemp failure stops before the inventory"
fi

# ── short run: phases, honest labels, cleanup, real CPU load ──────────────
start_nt -y 3
pid=$NT_PID
log=$NT_LOG
load_seen=""
spins=0
deadline=$((SECONDS + 25))
while (( SECONDS < deadline )); do
  if [[ -z $load_seen ]] && grep -q "PHASE 2" "$log"; then
    # Two /proc/stat samples while the storm is supposed to be pegged.
    read -r b1 t1 < <(awk '/^cpu /{b=$2+$3+$4+$7+$8+$9; t=b+$5+$6; print b, t}' /proc/stat)
    sleep 0.4
    read -r b2 t2 < <(awk '/^cpu /{b=$2+$3+$4+$7+$8+$9; t=b+$5+$6; print b, t}' /proc/stat)
    dt=$((t2 - t1)); db=$((b2 - b1))
    pct=0
    (( dt > 0 )) && pct=$((db * 100 / dt))
    if (( pct >= 50 )); then
      load_seen="busy ${pct}%"
    else
      load_seen="low ${pct}%"
    fi
    spins="$(spinner_count)"
  fi
  grep -q "VERDICT" "$log" && break
  sleep 0.2
done
if wait_or_kill "$pid" 50; then
  ok "short run exits on its own"
  wait "$pid" 2>/dev/null
  rc=$?
  [[ $rc -eq 0 ]] && ok "short run exits 0" || fail "short run exits 0" "exit $rc"
else
  fail "short run exits on its own" "had to SIGKILL pid $pid"
  fail "short run exits 0" "killed"
fi

for phase in "PHASE 1" "PHASE 2" "PHASE 3" "PHASE 5" "PHASE 6" "VERDICT"; do
  grep -q "$phase" "$log" && ok "output contains $phase" || fail "output contains $phase"
done
# The NPU storm needs the device node, hailortcli, and a HEF — npu_armed() in
# the script. A node alone is not enough, and the inventory says so.
if [[ -e /dev/hailo0 ]] && ! grep -q "NPU storm skipped" "$log"; then
  grep -q "PHASE 4" "$log" && ok "PHASE 4 runs when the NPU storm is armed" \
    || fail "PHASE 4 runs when the NPU storm is armed"
else
  if grep -q "PHASE 4" "$log"; then
    fail "PHASE 4 is skipped when the NPU storm is not armed"
  else
    ok "PHASE 4 is skipped when the NPU storm is not armed"
  fi
fi
if grep -q "TensorRT flood" "$log"; then
  fail "GPU-off run does not label phase 3 as a TensorRT flood"
else
  ok "GPU-off run does not label phase 3 as a TensorRT flood"
fi
if grep -Eq 'cpu -1°C|gpu -1°C|soc -1°C|npu -1°C' "$log"; then
  fail "missing thermal zones are omitted, not printed as -1°C" "$(grep -E -- '-1°C' "$log" | head -1)"
else
  ok "missing thermal zones are omitted, not printed as -1°C"
fi
[[ ${load_seen:-} == busy* ]] && ok "CPU storm actually loads the machine (${load_seen}, ${spins:-0} spinners)" \
  || fail "CPU storm actually loads the machine" "${load_seen:-phase 2 never seen}; spinners ${spins:-0}"
[[ $(spinner_count) -eq 0 ]] && ok "short run leaves no awk spinners" \
  || fail "short run leaves no awk spinners" "$(spinner_count) still running"
[[ $(tmp_dirs) == "$before" ]] && ok "short run removes its temp dir" \
  || fail "short run removes its temp dir" "$(tmp_dirs)"

# ── SIGTERM aborts the run ─────────────────────────────────────────────────
# Only TERM can be tested from here: bash starts a `&` child with SIGINT
# ignored, and a signal ignored at entry cannot be trapped, so an INT sent to
# a backgrounded nanotax proves nothing. INT and HUP share the TERM handler
# in the script, and Ctrl-C from a real terminal is covered by hand.

# During idle, before any spinner exists: the run must end, not continue
# into the CPU storm after cleanup.
start_nt -y 30
pid=$NT_PID
log=$NT_LOG
if wait_for_phase "$pid" "$log" "PHASE 1" && ! grep -q "PHASE 2" "$log"; then
  ok "signal test caught the run during idle"
else
  fail "signal test caught the run during idle"
fi
kill -TERM "$pid" 2>/dev/null || true
if wait_or_kill "$pid" 10; then
  ok "SIGTERM during idle ends the process within 2s"
  wait "$pid" 2>/dev/null
  rc=$?
  [[ $rc -eq 143 ]] && ok "SIGTERM during idle exits 143" \
    || fail "SIGTERM during idle exits 143" "exit $rc"
  grep -q "PHASE 2" "$log" && fail "SIGTERM during idle does not start the CPU storm" \
    || ok "SIGTERM during idle does not start the CPU storm"
else
  fail "SIGTERM during idle ends the process within 2s" "had to SIGKILL pid $pid"
  fail "SIGTERM during idle exits 143" "killed"
  fail "SIGTERM during idle does not start the CPU storm" "never exited"
fi
[[ $(tmp_dirs) == "$before" ]] && ok "SIGTERM during idle removes the temp dir" \
  || fail "SIGTERM during idle removes the temp dir" "$(tmp_dirs)"

# During the CPU storm, with every spinner alive: the trap has to take the
# workers down with it. This is the case the header actually promises.
start_nt -y 30
pid=$NT_PID
log=$NT_LOG
wait_for_phase "$pid" "$log" "PHASE 2" || true
sleep 0.5
spins="$(spinner_count)"
[[ $spins -gt 0 ]] && ok "signal test caught the run mid-storm ($spins spinners)" \
  || fail "signal test caught the run mid-storm" "no spinners; $(grep -o 'PHASE [0-9]' "$log" | tail -1)"
kill -TERM "$pid" 2>/dev/null || true
if wait_or_kill "$pid" 10; then
  ok "SIGTERM mid-storm ends the process within 2s"
  wait "$pid" 2>/dev/null
  rc=$?
  [[ $rc -eq 143 ]] && ok "SIGTERM mid-storm exits 143" \
    || fail "SIGTERM mid-storm exits 143" "exit $rc"
else
  fail "SIGTERM mid-storm ends the process within 2s" "had to SIGKILL pid $pid"
  fail "SIGTERM mid-storm exits 143" "killed"
fi
sleep 0.3
[[ $(spinner_count) -eq 0 ]] && ok "SIGTERM mid-storm leaves no awk spinners" \
  || fail "SIGTERM mid-storm leaves no awk spinners" "$(spinner_count) still running"
[[ $(tmp_dirs) == "$before" ]] && ok "SIGTERM mid-storm removes the temp dir" \
  || fail "SIGTERM mid-storm removes the temp dir" "$(tmp_dirs)"
reap_spinners

# ── committed bytecode is the SVG tool, not a second program ──────────────
pyc="$ROOT/tools/__pycache__/ansi2svg.cpython-312.pyc"
if [[ -f $pyc ]]; then
  fail "tools/__pycache__ is not committed" "ansi2svg.cpython-312.pyc is in the tree; it embeds a local build path"
else
  ok "tools/__pycache__ is not committed"
fi

say ""
say "$PASS passed, $FAIL failed"
rm -rf "${KEEP[@]}" 2>/dev/null || true
[[ $FAIL -eq 0 ]]
