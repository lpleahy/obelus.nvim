#!/bin/sh
# Self-tests for the UI snapshot harness itself (`make ui-selftest`, ~1.5 min).
#
# Rule: this script never signals anything. It OBSERVES (ps, files) and asserts.
# Every signal below is sent by supervise.pl to a process group it created and
# whose leader it has not yet reaped; the decoy is stopped the same way.
#
#   0. foreign: an unrelated `nvim --embed` (the decoy, started here, not by the
#      harness) runs throughout; its pid is injected into every pid record the
#      harness writes (the self-test pid logs). It must survive everything.
#   1. timeout: a child wedged in Lua trips the RPC guard; rpc.lua reaps it
#   2. error:   a scenario that raises is reported as ERROR
#   3. SIGTERM mid-run: the supervisor tears down its group and removes the dir
#   4. delay:   a 2.5 s stall before each progress/stream/popup capture leaves the
#               snapshots byte-identical
#   5. SIGKILL of the supervisor mid-run: the orphaned parent stops, its child is
#      reaped, the dir is removed
#   6. parent already exited, then TERM: the supervisor signals nothing
#   7. SIGKILL of the supervisor BEFORE the parent's Lua starts: the parent still
#      notices, captures nothing, removes the dir
# After each case: no recorded child (other than the decoy) is alive, the run's
# temp base is empty.
set -u
here=$(cd "$(dirname "$0")" && pwd)
base=${OBELUS_UI_TMPBASE:-${TMPDIR:-/tmp}}
work=$(mktemp -d "${base%/}/obelus-selftest.XXXXXX") || exit 2
SUP="perl $here/supervise.pl"
decoy_sup=
finish() {
  if [ -n "$decoy_sup" ]; then
    echo stop >"$work/stop-decoy" # its supervisor KILLs the decoy's group, reaps it
    wait "$decoy_sup" 2>/dev/null
  fi
  rm -rf "$work"
}
trap finish EXIT
fails=0

ok() { echo "ok    $1"; }
bad() {
  echo "FAIL  $1"
  fails=$((fails + 1))
}
alive() { ps -p "$1" -o pid= >/dev/null 2>&1; }
poll() { # poll <tenths> <shell condition>: bounded wait for a condition
  n=0
  while [ $n -lt "$1" ]; do
    eval "$2" && return 0
    sleep 0.1
    n=$((n + 1))
  done
  return 1
}

# 0. the decoy: an unrelated embedded nvim, its stdin held open by `sleep`
cat >"$work/decoy.sh" <<'EOF'
echo $$ >"$1"
exec nvim --embed --headless -n -i NONE -u NONE --noplugin
EOF
$SUP --signal-after "$work/stop-decoy" --signal KILL -- \
  sh -c 'sleep 900 | sh "$0" "$1"' "$work/decoy.sh" "$work/decoy.pid" >/dev/null 2>&1 &
decoy_sup=$!
poll 100 '[ -s "$work/decoy.pid" ]' || bad "decoy did not start"
decoy=$(cat "$work/decoy.pid")
seed() { echo "$decoy" >"$1"; } # inject the foreign pid into a record

# observe only: every recorded pid except the decoy must be gone; base empty
assert_clean() {
  label=$1 pidlog=$2 tbase=$3
  if [ "$(wc -l <"$pidlog")" -lt 2 ]; then
    bad "$label: no harness child pid was recorded"
    return
  fi
  while read -r p; do
    if [ "$p" != "$decoy" ] && alive "$p"; then
      bad "$label: harness child pid $p still alive"
      return
    fi
  done <"$pidlog"
  if [ -n "$(ls -A "$tbase")" ]; then
    bad "$label: temp dir left behind: $(ls -A "$tbase")"
    return
  fi
  ok "$label: no harness child alive, temp dir removed"
}

# 1. forced RPC timeout
mkdir "$work/t1"
seed "$work/t1.pids"
out=$(OBELUS_UI_TMPBASE="$work/t1" OBELUS_UI_GUARD_MS=1500 OBELUS_UI_ONLY=_selftest_hang \
  OBELUS_UI_PIDLOG="$work/t1.pids" sh "$here/run.sh" 2>&1)
rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q 'rpc-fault'; then
  ok "timeout: reported as a transport fault (exit $rc)"
else
  bad "timeout: unexpected outcome (exit $rc): $out"
fi
assert_clean "timeout" "$work/t1.pids" "$work/t1"

# 2. scenario error
mkdir "$work/t2"
seed "$work/t2.pids"
out=$(OBELUS_UI_TMPBASE="$work/t2" OBELUS_UI_ONLY=_selftest_error \
  OBELUS_UI_PIDLOG="$work/t2.pids" sh "$here/run.sh" 2>&1)
rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q '^ERROR .*deliberate scenario failure'; then
  ok "error: reported as ERROR (exit $rc)"
else
  bad "error: unexpected outcome (exit $rc): $out"
fi
assert_clean "error" "$work/t2.pids" "$work/t2"

# 3. SIGTERM to the run (its supervisor) while the child is wedged
mkdir "$work/t3"
seed "$work/t3.pids"
OBELUS_UI_TMPBASE="$work/t3" OBELUS_UI_GUARD_MS=600000 OBELUS_UI_ONLY=_selftest_hang \
  OBELUS_UI_PIDLOG="$work/t3.pids" OBELUS_UI_SUPERVISE_LOG="$work/t3.sup" \
  $SUP --signal-after "$work/t3.pids" --min-lines 2 --signal TERM -- sh "$here/run.sh" >"$work/t3.out" 2>&1
rc=$?
if [ $rc -eq 143 ] && grep -q '^signal TERM' "$work/t3.sup"; then
  ok "sigterm: run exited 143; its supervisor signalled its own group"
else
  bad "sigterm: exit $rc; supervisor log: $(cat "$work/t3.sup" 2>/dev/null)"
fi
assert_clean "sigterm" "$work/t3.pids" "$work/t3"

# 4. injected wall-clock delay: snapshots must still match byte-for-byte
mkdir "$work/t4"
out=$(OBELUS_UI_TMPBASE="$work/t4" OBELUS_UI_DELAY_MS=2500 \
  OBELUS_UI_ONLY=progress_,stream_,chat_popup,band_popup sh "$here/run.sh" 2>&1)
rc=$?
if [ $rc -eq 0 ]; then
  ok "delay: $(printf '%s\n' "$out" | tail -1)"
else
  bad "delay: snapshots changed under a 2.5 s stall: $out"
fi

# 5. SIGKILL of the run's supervisor while the child is wedged (short guard)
mkdir "$work/t5"
seed "$work/t5.pids"
OBELUS_UI_TMPBASE="$work/t5" OBELUS_UI_GUARD_MS=1500 OBELUS_UI_ONLY=_selftest_hang \
  OBELUS_UI_PIDLOG="$work/t5.pids" \
  $SUP --signal-after "$work/t5.pids" --min-lines 2 --signal KILL -- sh "$here/run.sh" >"$work/t5.out" 2>&1
rc=$?
poll 600 '[ -z "$(ls -A "$work/t5")" ]'
if [ $rc -eq 137 ]; then
  ok "sigkill: supervisor killed (exit $rc)"
else
  bad "sigkill: unexpected exit $rc"
fi
assert_clean "sigkill" "$work/t5.pids" "$work/t5"

# 6. the parent has already exited (and been reaped) when TERM arrives
mkdir "$work/t6"
OBELUS_UI_TMPBASE="$work/t6" OBELUS_NVIM=/usr/bin/true OBELUS_UI_SUPERVISE_LOG="$work/t6.sup" \
  OBELUS_UI_PAUSE_AFTER_REAP=3000 \
  $SUP --signal-after "$work/t6.sup" --signal TERM -- sh "$here/run.sh" >"$work/t6.out" 2>&1
rc=$?
if [ $rc -eq 143 ] && grep -q '^reaped' "$work/t6.sup" && ! grep -q '^signal' "$work/t6.sup" &&
  [ -z "$(ls -A "$work/t6")" ]; then
  ok "exited-parent: TERM after the leader was reaped signalled nothing; dir removed"
else
  bad "exited-parent: exit $rc; log: $(cat "$work/t6.sup" 2>/dev/null); left: $(ls -A "$work/t6")"
fi

# 7. supervisor SIGKILLed before the parent's Lua runs (a launcher holds it back)
mkdir "$work/t7"
cat >"$work/launch.sh" <<'EOF'
echo ready >"$LAUNCH_READY"
while [ ! -e "$LAUNCH_GO" ]; do sleep 0.1; done
exec nvim "$@"
EOF
chmod +x "$work/launch.sh"
LAUNCH_READY="$work/t7.ready" LAUNCH_GO="$work/t7.go" OBELUS_UI_TMPBASE="$work/t7" \
  OBELUS_NVIM="$work/launch.sh" OBELUS_UI_ONLY=progress_finish_ok OBELUS_UI_PIDLOG="$work/t7.pids" \
  $SUP --signal-after "$work/t7.ready" --signal KILL -- sh "$here/run.sh" >"$work/t7.out" 2>&1
rc=$?
echo go >"$work/t7.go"
poll 600 '[ -z "$(ls -A "$work/t7")" ] && grep -q "supervisor died" "$work/t7.out"'
if [ $rc -eq 137 ] && grep -q 'supervisor died' "$work/t7.out" && ! grep -q '^\.' "$work/t7.out" &&
  [ -z "$(ls -A "$work/t7")" ] && [ ! -s "$work/t7.pids" ]; then
  ok "early-sigkill: orphaned parent captured nothing and removed the dir"
else
  bad "early-sigkill: exit $rc; out: $(cat "$work/t7.out"); left: $(ls -A "$work/t7")"
fi

# 0. the decoy survived every case above
if alive "$decoy"; then
  ok "foreign: unrelated nvim --embed (pid $decoy, injected into every pid record) never signalled"
else
  bad "foreign: unrelated nvim --embed (pid $decoy) is gone"
fi

echo "selftest: $fails failure(s)"
[ $fails -eq 0 ]
