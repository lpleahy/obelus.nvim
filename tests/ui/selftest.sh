#!/bin/sh
# Self-tests for the UI snapshot harness itself (`make ui-selftest`, ~1.5 min).
#
# Rule: this script never signals anything. It OBSERVES (ps, files) and asserts.
# Every signal below is sent by supervise.pl to a process group it created and
# whose guardian (leader) it has not yet reaped; the decoy is stopped the same way.
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
#   8. parent-exit: the group's first process exits 42 while a same-group child
#      (ignoring TERM) is still running: the supervisor TERMs then KILLs the group
#      before it lets go of it; exit 42; nothing survives the supervisor
#   9. parent-exit-harness: the same with the real harness — the parent nvim
#      exits 42 during the scenario RPC of a child busy in Lua
#  10. parent-exit-race: TERM reaches the supervisor around the parent's exit
#  11. no-perl: run.sh on a PATH without perl fails clearly, allocates nothing
# After each case: no recorded child (other than the decoy) is alive, the run's
# temp base is empty.
#
# OBELUS_UI_SELFTEST_ONLY=name,...  run only these cases (tests/ui/mutations.sh):
# timeout error sigterm delay sigkill exited-parent early-sigkill parent-exit
# parent-exit-harness parent-exit-race no-perl. The decoy check always runs.
set -u
here=$(cd "$(dirname "$0")" && pwd)
if ! command -v perl >/dev/null 2>&1 || ! perl -MPOSIX -MTime::HiRes -e 1 >/dev/null 2>&1; then
  echo "tests/ui/selftest.sh: perl with the core POSIX and Time::HiRes modules is required" >&2
  exit 2
fi
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
want() { # want <case>: selected by OBELUS_UI_SELFTEST_ONLY (all when unset)
  [ -z "${OBELUS_UI_SELFTEST_ONLY:-}" ] && return 0
  case ",$OBELUS_UI_SELFTEST_ONLY," in *",$1,"*) return 0 ;; esac
  return 1
}
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
if want timeout; then
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
fi

# 2. scenario error
if want error; then
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
fi

# 3. SIGTERM to the run (its supervisor) while the child is wedged
if want sigterm; then
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
fi

# 4. injected wall-clock delay: snapshots must still match byte-for-byte
if want delay; then
  mkdir "$work/t4"
  out=$(OBELUS_UI_TMPBASE="$work/t4" OBELUS_UI_DELAY_MS=2500 \
    OBELUS_UI_ONLY=progress_,stream_,chat_popup,band_popup sh "$here/run.sh" 2>&1)
  rc=$?
  if [ $rc -eq 0 ]; then
    ok "delay: $(printf '%s\n' "$out" | tail -1)"
  else
    bad "delay: snapshots changed under a 2.5 s stall: $out"
  fi
fi

# 5. SIGKILL of the run's supervisor while the child is wedged (short guard)
if want sigkill; then
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
fi

# 6. the parent has already exited (and been reaped) when TERM arrives
if want exited-parent; then
  mkdir "$work/t6"
  OBELUS_UI_TMPBASE="$work/t6" OBELUS_NVIM=/usr/bin/true OBELUS_UI_SUPERVISE_LOG="$work/t6.sup" \
    OBELUS_UI_PAUSE_AFTER_REAP=3000 \
    $SUP --signal-after "$work/t6.sup" --signal TERM -- sh "$here/run.sh" >"$work/t6.out" 2>&1
  rc=$?
  if [ $rc -eq 143 ] && grep -q '^reaped' "$work/t6.sup" && ! grep -q '^signal' "$work/t6.sup" &&
    [ -z "$(ls -A "$work/t6")" ]; then
    ok "exited-parent: TERM after the group was released signalled nothing; dir removed"
  else
    bad "exited-parent: exit $rc; log: $(cat "$work/t6.sup" 2>/dev/null); left: $(ls -A "$work/t6")"
  fi
fi

# 7. supervisor SIGKILLed before the parent's Lua runs (a launcher holds it back)
if want early-sigkill; then
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
fi

# The parent-exit cases. Their stragglers end on their own after a deadline
# (8-10 s), so a supervisor that fails to stop them (a mutation) leaks nothing:
# on failure we wait them out, observing only.
wait_out() { # wait_out <pidlog>: bounded wait for every non-decoy pid to end
  wo_log=$1
  poll 150 'gone=1; while read -r p; do [ "$p" != "$decoy" ] && alive "$p" && gone=0; done <"$wo_log"; [ $gone -eq 1 ]' ||
    bad "a straggler outlived its own deadline: $(cat "$wo_log")"
}
# log: a TERM to the group, and "reaped" (the group released) as the last line
log_ok() { grep -q '^signal TERM' "$1" && [ "$(tail -1 "$1")" = reaped ]; }

# a same-group child that ignores TERM, never reads stdin, ends after 8 s
cat >"$work/straggler.pl" <<'EOF'
$SIG{TERM} = 'IGNORE';
open my $f, '>>', $ARGV[0] or die; print $f "$$\n"; close $f;
my $end = time + 8;
sleep 1 while time < $end;
EOF
# the group's first process: start the straggler, wait until it is recorded,
# (optionally touch a marker and linger 0.4 s), then exit 42
cat >"$work/crash.sh" <<'EOF'
perl "$1" "$2" &
while [ "$(wc -l <"$2")" -lt 2 ]; do sleep 0.05; done
if [ -n "${3:-}" ]; then echo now >"$3"; sleep 0.4; fi
exit 42
EOF

# 8. the parent exits first, its child still running in the group
if want parent-exit; then
  mkdir -p "$work/t8/run"
  seed "$work/t8.pids"
  $SUP --rmdir "$work/t8/run" --log "$work/t8.sup" -- \
    sh "$work/crash.sh" "$work/straggler.pl" "$work/t8.pids" >"$work/t8.out" 2>&1
  rc=$?
  if [ $rc -eq 42 ] && log_ok "$work/t8.sup" && grep -q '^signal KILL' "$work/t8.sup"; then
    ok "parent-exit: exit 42 kept; the group was TERMed, then KILLed, before release"
  else
    bad "parent-exit: exit $rc; supervisor log: $(tr '\n' ' ' <"$work/t8.sup" 2>/dev/null)"
  fi
  assert_clean "parent-exit" "$work/t8.pids" "$work/t8" # right away: no polling
  wait_out "$work/t8.pids"
fi

# 9. the same with the real harness: the parent nvim exits 42 mid-RPC while its
# embedded child is busy in Lua (bounded to 10 s by OBELUS_UI_HANG_MAX_MS)
if want parent-exit-harness; then
  mkdir "$work/t9"
  seed "$work/t9.pids"
  OBELUS_UI_TMPBASE="$work/t9" OBELUS_UI_GUARD_MS=600000 OBELUS_UI_ONLY=_selftest_hang \
    OBELUS_UI_HANG_MAX_MS=10000 OBELUS_UI_SELFTEST_PARENT_EXIT=42 \
    OBELUS_UI_PIDLOG="$work/t9.pids" OBELUS_UI_SUPERVISE_LOG="$work/t9.sup" \
    sh "$here/run.sh" >"$work/t9.out" 2>&1
  rc=$?
  if [ $rc -eq 42 ] && log_ok "$work/t9.sup"; then
    ok "parent-exit-harness: exit 42 kept; the busy embedded child was stopped before release"
  else
    bad "parent-exit-harness: exit $rc; supervisor log: $(tr '\n' ' ' <"$work/t9.sup" 2>/dev/null)"
  fi
  assert_clean "parent-exit-harness" "$work/t9.pids" "$work/t9"
  wait_out "$work/t9.pids"
fi

# 10. TERM reaches the supervisor ~0.1 s after the parent exits 42, child present
if want parent-exit-race; then
  mkdir -p "$work/t10/run"
  seed "$work/t10.pids"
  $SUP --signal-after "$work/t10.mark" --signal TERM -- \
    $SUP --rmdir "$work/t10/run" --log "$work/t10.sup" -- \
    sh "$work/crash.sh" "$work/straggler.pl" "$work/t10.pids" "$work/t10.mark" >"$work/t10.out" 2>&1
  rc=$?
  if { [ $rc -eq 143 ] || [ $rc -eq 42 ]; } && log_ok "$work/t10.sup"; then
    ok "parent-exit-race: exit $rc; the group was stopped before release"
  else
    bad "parent-exit-race: exit $rc; supervisor log: $(tr '\n' ' ' <"$work/t10.sup" 2>/dev/null)"
  fi
  assert_clean "parent-exit-race" "$work/t10.pids" "$work/t10"
  wait_out "$work/t10.pids"
fi

# 11. no perl on PATH: a clear error, non-zero, and no temp dir allocated
if want no-perl; then
  mkdir "$work/t11" "$work/noperl"
  for t in sh dirname mktemp mkdir rm; do
    tp=$(command -v $t) && ln -s "$tp" "$work/noperl/$t"
  done
  out=$(PATH="$work/noperl" OBELUS_UI_TMPBASE="$work/t11" "$(command -v sh)" "$here/run.sh" 2>&1)
  rc=$?
  if [ $rc -ne 0 ] && [ $rc -ne 127 ] && printf '%s' "$out" | grep -q 'perl .*is required' &&
    [ -z "$(ls -A "$work/t11")" ]; then
    ok "no-perl: exit $rc with a clear message; nothing allocated"
  else
    bad "no-perl: exit $rc: $out; left: $(ls -A "$work/t11")"
  fi
fi

# 0. the decoy survived every case above, including the group TERM/KILLs
if alive "$decoy"; then
  ok "foreign: unrelated nvim --embed (pid $decoy, injected into every pid record) never signalled"
else
  bad "foreign: unrelated nvim --embed (pid $decoy) is gone"
fi

echo "selftest: $fails failure(s)"
[ $fails -eq 0 ]
