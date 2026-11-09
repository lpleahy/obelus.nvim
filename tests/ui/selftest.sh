#!/bin/sh
# Self-tests for the UI snapshot harness itself (`make ui-selftest`, ~30 s):
#   1. timeout: a child wedged in Lua trips the RPC guard; the harness reaps it
#      (no live child, no temp dir left, no wrapper fallback needed)
#   2. error:   a scenario that raises is reported as ERROR; child + temp dir gone
#   3. signal:  SIGTERM to the wrapper mid-run kills the parent and the child and
#               removes the temp dir
#   4. delay:   a 2.5 s wall-clock stall between arranging and capturing every
#               progress/stream/popup scenario leaves the snapshots byte-identical
#   5. sigkill: SIGKILL to the wrapper (no trap can run): the orphaned parent stops,
#               its child is reaped and the run's temp dir is still removed
#   6. foreign: an unrelated `nvim --embed` (started here, NOT by the harness) is
#               alive through all of the above, including the signal paths, and
#               must never be signalled
# Everything runs under a private mktemp dir, removed by exact path at the end.
set -u
here=$(cd "$(dirname "$0")" && pwd)
base=${OBELUS_UI_TMPBASE:-${TMPDIR:-/tmp}}
work=$(mktemp -d "${base%/}/obelus-selftest.XXXXXX") || exit 2
decoy= feeder=
finish() {
  [ -n "$decoy" ] && kill -KILL "$decoy" 2>/dev/null
  [ -n "$feeder" ] && kill -KILL "$feeder" 2>/dev/null
  wait 2>/dev/null
  rm -rf "$work"
}
trap finish EXIT
trap 'exit 130' INT TERM
fails=0

ok() { echo "ok    $1"; }
bad() {
  echo "FAIL  $1"
  fails=$((fails + 1))
}

# every pid in $1 must be gone; $2 (a TMPBASE) must hold no leftover entries
assert_clean() {
  label=$1 pidlog=$2 tbase=$3
  if [ ! -s "$pidlog" ]; then
    bad "$label: no child pid was recorded"
    return
  fi
  while read -r p; do
    if kill -0 "$p" 2>/dev/null; then
      bad "$label: child pid $p still alive"
      kill -KILL "$p" 2>/dev/null
      return
    fi
  done <"$pidlog"
  if [ -n "$(ls -A "$tbase")" ]; then
    bad "$label: temp dir left behind: $(ls -A "$tbase")"
    return
  fi
  ok "$label: child reaped, temp dir removed"
}

# 6 (setup). a foreign embedded nvim: a sibling of the harness, kept alive by a
# feeder that holds its stdin open; both pids are ours (this script's) to clean up
sh -c 'echo $$ >"$1"; exec sleep 900' sh "$work/feeder.pid" | \
  nvim --embed --headless -n -i NONE -u NONE --noplugin >/dev/null 2>&1 &
decoy=$!
n=0
while [ ! -s "$work/feeder.pid" ] && [ $n -lt 100 ]; do
  sleep 0.1
  n=$((n + 1))
done
feeder=$(cat "$work/feeder.pid")

# 1. forced RPC timeout
mkdir "$work/t1"
out=$(OBELUS_UI_TMPBASE="$work/t1" OBELUS_UI_GUARD_MS=1500 OBELUS_UI_ONLY=_selftest_hang \
  OBELUS_UI_PIDLOG="$work/t1.pids" sh "$here/run.sh" 2>&1)
rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q 'rpc-fault' && ! printf '%s' "$out" | grep -q 'reaped leftover'; then
  ok "timeout: reported as a transport fault (exit $rc), reaped by the harness itself"
else
  bad "timeout: unexpected outcome (exit $rc): $out"
fi
assert_clean "timeout" "$work/t1.pids" "$work/t1"

# 2. scenario error
mkdir "$work/t2"
out=$(OBELUS_UI_TMPBASE="$work/t2" OBELUS_UI_ONLY=_selftest_error \
  OBELUS_UI_PIDLOG="$work/t2.pids" sh "$here/run.sh" 2>&1)
rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q '^ERROR .*deliberate scenario failure'; then
  ok "error: reported as ERROR (exit $rc)"
else
  bad "error: unexpected outcome (exit $rc): $out"
fi
assert_clean "error" "$work/t2.pids" "$work/t2"

# 3. SIGTERM to the wrapper while the child is wedged (guard far away)
mkdir "$work/t3"
OBELUS_UI_TMPBASE="$work/t3" OBELUS_UI_GUARD_MS=600000 OBELUS_UI_ONLY=_selftest_hang \
  OBELUS_UI_PIDLOG="$work/t3.pids" sh "$here/run.sh" >"$work/t3.out" 2>&1 &
wrapper=$!
# wait (bounded) for the child to be spawned: its pid lands in the run's pid file
n=0
while [ ! -s "$work/t3.pids" ] && [ $n -lt 600 ]; do
  sleep 0.1
  n=$((n + 1))
done
sleep 0.5 # let the scenario's busy loop start
kill -TERM "$wrapper"
wait "$wrapper"
rc=$?
if [ $rc -ne 0 ]; then
  ok "signal: wrapper exited $rc on SIGTERM"
else
  bad "signal: wrapper exited 0 on SIGTERM"
fi
assert_clean "signal" "$work/t3.pids" "$work/t3"

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

# 5. SIGKILL to the wrapper while the child is wedged (short guard)
mkdir "$work/t5"
OBELUS_UI_TMPBASE="$work/t5" OBELUS_UI_GUARD_MS=1500 OBELUS_UI_ONLY=_selftest_hang \
  OBELUS_UI_PIDLOG="$work/t5.pids" sh "$here/run.sh" >"$work/t5.out" 2>&1 &
wrapper=$!
n=0
while [ ! -s "$work/t5.pids" ] && [ $n -lt 600 ]; do
  sleep 0.1
  n=$((n + 1))
done
sleep 0.5
kill -KILL "$wrapper"
wait "$wrapper" 2>/dev/null
# bounded wait for the orphaned parent to finish its guard + reap + remove the dir
n=0
while [ -n "$(ls -A "$work/t5")" ] && [ $n -lt 600 ]; do
  sleep 0.1
  n=$((n + 1))
done
assert_clean "sigkill" "$work/t5.pids" "$work/t5"

# 6. the foreign embedded nvim survived every run and signal path above
if kill -0 "$decoy" 2>/dev/null; then
  ok "foreign: unrelated nvim --embed (pid $decoy) was never signalled"
else
  bad "foreign: unrelated nvim --embed (pid $decoy) was killed"
fi

echo "selftest: $fails failure(s)"
[ $fails -eq 0 ]
