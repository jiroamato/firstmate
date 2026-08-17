#!/usr/bin/env bash
# Behavior tests for the #1508-upstream lock fixes in bin/fm-wake-lib.sh:
# a procfs cross-check that overrules kill -0's false-alive answer where the
# host publishes per-pid procfs entries, and a bounded fm_lock_acquire_wait
# that refuses with the holder named instead of spinning forever behind a
# lock whose recorded holder never dies.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORLD=$(fm_test_tmproot fm-lock-bounded-wait)
export FM_HOME="$WORLD/home"
export FM_STATE_OVERRIDE="$WORLD/home/state"
mkdir -p "$FM_STATE_OVERRIDE"
STATE="$FM_STATE_OVERRIDE"

# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"

# --- fm_pid_alive procfs cross-check ----------------------------------------

# A live pid with a live procfs entry stays alive under the cross-check.
fm_pid_alive "$$" || fail "own live pid must read alive"
pass "a live pid with a procfs entry reads alive"

# The MSYS false-alive shape: kill -0 answers alive (we use our own live pid
# to force that) but the procfs root has a self entry and NO entry for the
# pid. The cross-check must overrule the probe and report death.
FAKE_PROC="$WORLD/fakeproc"
mkdir -p "$FAKE_PROC/self"
if FM_PROC_ROOT_OVERRIDE="$FAKE_PROC" fm_pid_alive "$$"; then
  fail "a missing procfs entry must overrule a false-alive kill -0 probe"
fi
pass "a missing procfs entry proves death even when kill -0 says alive"

# A procfs root without a self entry (macOS shape) must NOT engage the
# cross-check: the plain kill -0 answer stands.
NOPROC="$WORLD/noproc"
mkdir -p "$NOPROC"
FM_PROC_ROOT_OVERRIDE="$NOPROC" fm_pid_alive "$$" \
  || fail "a host without procfs must keep the plain kill -0 answer"
pass "a host without procfs keeps the plain kill -0 answer"

# --- bounded fm_lock_acquire_wait -------------------------------------------

# Hold a lock with a genuinely live holder process, then require a 1-second
# bounded wait to refuse quickly, loudly, and with the holder named.
HELD="$STATE/.bounded-wait-test.lock"
sleep 60 &
HOLDER=$!
mkdir -p "$HELD"
printf '%s\n' "$HOLDER" > "$HELD/pid"

start=$(date +%s)
err=$(FM_LOCK_ACQUIRE_TIMEOUT=1 fm_lock_acquire_wait "$HELD" 2>&1)
rc=$?
elapsed=$(( $(date +%s) - start ))
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null || true

[ "$rc" -ne 0 ] || fail "bounded wait must refuse a lock whose holder stays alive"
[ "$elapsed" -le 5 ] || fail "bounded wait took ${elapsed}s against a 1s bound"
case "$err" in
  *"could not acquire lock"*"$HOLDER"*) : ;;
  *) fail "timeout diagnostic must name the lock and recorded holder, got: $err" ;;
esac
pass "a bounded wait refuses a live-held lock within its bound and names the holder"

rm -rf "$HELD"

# With the bound in place, an uncontended lock still acquires immediately.
FREE="$STATE/.bounded-wait-free.lock"
FM_LOCK_ACQUIRE_TIMEOUT=1 fm_lock_acquire_wait "$FREE" \
  || fail "an uncontended lock must acquire under the bounded wait"
fm_lock_release "$FREE"
pass "an uncontended lock acquires immediately under the bounded wait"

# A dead-holder lock is reclaimed (not timed out): seed a pid that is gone.
sleep 0.2 &
DEAD=$!
wait "$DEAD" 2>/dev/null || true
STALE="$STATE/.bounded-wait-stale.lock"
mkdir -p "$STALE"
printf '%s\n' "$DEAD" > "$STALE/pid"
# Age the record past the mid-acquire grace so reclamation is authorized.
sleep "${FM_LOCK_STALE_AFTER:-2}"
sleep 1
FM_LOCK_ACQUIRE_TIMEOUT=10 fm_lock_acquire_wait "$STALE" \
  || fail "a dead-holder lock must be reclaimed, not timed out"
fm_lock_release "$STALE"
pass "a dead-holder lock is reclaimed within the bound"

echo "fm-lock-bounded-wait: all tests passed"
