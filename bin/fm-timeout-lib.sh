#!/usr/bin/env bash
# fm-timeout-lib.sh - the single owner of bounded command execution.
#
# Sourced, never executed. Provides one hard-bound runner so no caller has to
# re-derive the coreutils/BSD/perl selection, and so every bounded call in this
# repo agrees on what "the bound was hit" means.
#
#   fm_timeout_mechanism
#       Prints the mechanism fm_run_timed will use on this host: "timeout",
#       "gtimeout", "perl", or "bash". Set FM_TIMEOUT_MECHANISM_OVERRIDE=bash
#       to force the dependency-free fallback.
#
#   fm_run_timed <seconds> <command> [args...]
#       Runs the command with a hard bound. Exit status is the command's own,
#       except 124, which means the bound was hit (GNU timeout's convention,
#       reproduced by the perl and bash fallbacks).
#
#   fm_timeout_spawn_scale
#       Prints the positive integer a caller must multiply a DEFAULT bound by on
#       this host when the bounded work is dominated by process spawns rather
#       than by the work itself. Set FM_TIMEOUT_SPAWN_SCALE to a positive
#       integer to override the host answer. The host is read from $OSTYPE.
#
# A non-positive bound is not a bound: `timeout 0` and the perl fallback's
# `alarm 0` both disable the deadline, so callers must reject 0 before calling.
#
# All four mechanisms terminate the whole process GROUP, not just the direct
# child, so a hung grandchild (a vendor CLI spawned by a wrapper script, a git
# fetch spawned by a sweep) cannot outlive the bound. GNU/BSD `timeout` does
# this by default because it does not run the command in the foreground process
# group; the perl fallback does it explicitly with setpgrp plus a negative pid,
# and the bash fallback uses monitor mode to give the bounded child its own
# process group before signaling its negative pid.
set -u

fm_timeout_mechanism() {
  if [ "${FM_TIMEOUT_MECHANISM_OVERRIDE:-}" = bash ]; then
    printf 'bash\n'
  elif command -v timeout >/dev/null 2>&1; then
    printf 'timeout\n'
  elif command -v gtimeout >/dev/null 2>&1; then
    printf 'gtimeout\n'
  elif command -v perl >/dev/null 2>&1; then
    printf 'perl\n'
  else
    printf 'bash\n'
  fi
}

# A bound over a short shell pipeline is really a bound on process spawns: the
# runner, the shells it wraps the command in, and the handful of coreutils and
# jq passes the pipeline itself forks. A POSIX host spawns in about a
# millisecond, so a couple of seconds is already orders of magnitude more than
# such a read can need. A Windows Git Bash (MSYS) spawn costs a hundred
# milliseconds to a second on a host with real-time AV in the exec path, which
# puts the same pipeline tens of seconds out and makes every healthy read look
# wedged - see docs/verification/windows-snapshot-read-bounds.md for the
# measurements. Scaling the default keeps the bound meaning one thing on every
# host: far longer than a healthy read, still finite, so a wedged reader is
# always cut loose. Only DEFAULTS are scaled; a caller that names a bound gets
# exactly that bound, which is what keeps the wedged-read tests honest.
FM_TIMEOUT_SPAWN_SCALE_MSYS=20

# The host is read from $OSTYPE rather than `uname -s`, which is what the rest
# of this repo asks when it wants the path host. Two reasons, both specific to
# what this answer is for. Bash sets OSTYPE at build time, so reading it costs no
# spawn - and a spawn is the exact thing this function exists to price. And it
# cannot be answered by a stub on PATH: fixtures shim `uname` to drive unrelated
# platform branches (tests/fm-bearings-snapshot.test.sh pins the GNU-vs-BSD stat
# split that way), and a shimmed uname silently handing back a 1x scale would put
# the bounds back under a real read on this host.
fm_timeout_spawn_scale() {
  case "${FM_TIMEOUT_SPAWN_SCALE:-}" in
    ''|*[!0-9]*|0) ;;
    *) printf '%s\n' "$FM_TIMEOUT_SPAWN_SCALE"; return 0 ;;
  esac
  case "${OSTYPE:-}" in
    msys*|cygwin*|win32) printf '%s\n' "$FM_TIMEOUT_SPAWN_SCALE_MSYS" ;;
    *) printf '1\n' ;;
  esac
}

fm_run_bash_timeout() {
  local seconds=$1 command_status deadline_status child_pid watchdog_pid command_rc recorded_rc monitor_was_on=0
  shift
  command_status=$(mktemp "${TMPDIR:-/tmp}/fm-bash-timeout-command.XXXXXX" 2>/dev/null) || return 124
  deadline_status="${command_status}.deadline"
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m
  (
    set +m
    "$@"
    command_rc=$?
    printf '%s\n' "$command_rc" > "$command_status"
    exit "$command_rc"
  ) &
  child_pid=$!
  (
    set +m
    sleep "$seconds"
    printf 'expired\n' > "$deadline_status"
    kill -TERM -- "-$child_pid" 2>/dev/null || true
    sleep 0.2
    kill -KILL -- "-$child_pid" 2>/dev/null || true
    exit 124
  ) &
  watchdog_pid=$!
  [ "$monitor_was_on" -eq 1 ] || set +m

  if wait "$child_pid" 2>/dev/null; then
    command_rc=0
  else
    command_rc=$?
  fi
  if [ -s "$deadline_status" ]; then
    wait "$watchdog_pid" 2>/dev/null || true
    command_rc=124
  else
    kill -TERM -- "-$watchdog_pid" 2>/dev/null || kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    recorded_rc=$(cat "$command_status" 2>/dev/null || true)
    case "$recorded_rc" in ''|*[!0-9]*) ;; *) command_rc=$recorded_rc ;; esac
  fi
  rm -f "$command_status" "$deadline_status" 2>/dev/null || true
  return "$command_rc"
}

fm_run_external_timeout() {
  local runner=$1 seconds=$2 status_file runner_pid runner_rc command_rc
  shift 2
  status_file=$(mktemp "${TMPDIR:-/tmp}/fm-timeout-status.XXXXXX" 2>/dev/null) || return 124
  # Run timeout asynchronously so its pid - also the process-group id created
  # by GNU/BSD timeout without --foreground - remains available for cleanup.
  # A shell wrapper can exit promptly on TERM while one of its descendants
  # ignores TERM; timeout then considers the command finished and does not send
  # its configured KILL. Explicitly reap that leftover group on a real timeout.
  # shellcheck disable=SC2016  # Expansion is deliberately deferred to the child shell.
  "$runner" -k 1 "$seconds" bash -c '
    status_file=$1
    shift
    "$@"
    command_rc=$?
    printf "%s\n" "$command_rc" > "$status_file"
    exit "$command_rc"
  ' _ "$status_file" "$@" &
  runner_pid=$!
  if wait "$runner_pid"; then
    runner_rc=0
  else
    runner_rc=$?
  fi
  command_rc=$(cat "$status_file" 2>/dev/null || true)
  rm -f "$status_file" 2>/dev/null || true
  case "$command_rc" in
    ''|*[!0-9]*) ;;
    *) [ "$command_rc" -le 255 ] && return "$command_rc" ;;
  esac
  case "$runner_rc" in
    124|137)
      kill -KILL -- "-$runner_pid" 2>/dev/null || true
      return 124
      ;;
    *) return "$runner_rc" ;;
  esac
}

fm_run_timed() {  # <seconds> <command...>
  local seconds=$1
  shift
  case "$(fm_timeout_mechanism)" in
    timeout) fm_run_external_timeout timeout "$seconds" "$@" ;;
    gtimeout) fm_run_external_timeout gtimeout "$seconds" "$@" ;;
    perl)
      perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' \
        "$seconds" "$@"
      ;;
    bash) fm_run_bash_timeout "$seconds" "$@" ;;
    *) return 124 ;;
  esac
}
