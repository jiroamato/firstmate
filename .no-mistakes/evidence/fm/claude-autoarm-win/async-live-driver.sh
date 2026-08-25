#!/usr/bin/env bash
# Standalone driver for the backgrounded-asyncRewake phase added to
# tests/fm-claude-stop-autoarm-live-e2e.test.sh, run against real Claude Code
# with an isolated FM_HOME. Mirrors the test's async phase verbatim; the
# project tree is materialized with `git archive` because this worktree is on a
# detached HEAD (git clone of it has no remote HEAD to check out).
set -u

ROOT="C:/Users/amato/.no-mistakes/worktrees/ee8de15012e3/01M0V5BM540PGZC2BA9MNY02TA"
LAB=$(mktemp -d /tmp/fm-async-live.XXXXXX) || exit 1
PROJECT="$LAB/project"
ASYNC_HOME="$LAB/async-fmhome"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

command -v claude >/dev/null 2>&1 || fail "claude not found"
claude --version

mkdir -p "$PROJECT"
git -C "$ROOT" archive 1f4fc93 | tar -x -C "$PROJECT" || fail "archive extract failed"
git -C "$PROJECT" init -q
git -C "$PROJECT" -c user.name=fmtest -c user.email=fmtest@example.invalid \
  -c core.autocrlf=false add -A
git -C "$PROJECT" -c user.name=fmtest -c user.email=fmtest@example.invalid \
  -c core.autocrlf=false commit -qm init

# Rapid-death arm fixture, exactly as the live test installs it.
cat > "$PROJECT/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
N=$(cat "$FM_HOME/state/arm-count" 2>/dev/null || echo 0); N=$((N+1)); echo "$N" > "$FM_HOME/state/arm-count"
echo "arm-run=$N pid=$$" >> "$FM_HOME/state/arm-ran"
if [ "$N" -ge 3 ]; then
  rm -f "$FM_HOME/state/task.meta"
  printf 'watcher: attached pid=%s (beacon 2s)\n' "$$"
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-rapid-%s\n' "$N"
exit 0
SH
cat > "$PROJECT/bin/fm-wake-drain.sh" <<'SH'
#!/usr/bin/env bash
N=$(cat "$FM_HOME/state/drain-count" 2>/dev/null || echo 0); N=$((N+1)); echo "$N" > "$FM_HOME/state/drain-count"
echo "drain-run=$N" >> "$FM_HOME/state/drain-ran"
if [ "$N" -ge 3 ]; then
  rm -f "$FM_HOME/state/task.meta"
fi
printf 'stale: fixture-rapid drained\n'
SH
chmod +x "$PROJECT/bin/fm-watch-arm.sh" "$PROJECT/bin/fm-wake-drain.sh" "$PROJECT"/bin/*.sh

mkdir -p "$ASYNC_HOME/state" "$ASYNC_HOME/config" "$ASYNC_HOME/data"
printf 'project=fixture\nwindow=fixture\nbackend=tmux\n' > "$ASYNC_HOME/state/task.meta"
printf '9999999\n' > "$ASYNC_HOME/state/.lock"

ASYNC_PROMPT='Run exactly `bin/fm-session-start.sh` with Bash as your first tool call. After reading its digest, reply with exactly CYCLE0 and stop. If a Stop hook feedback message wakes you, reply with exactly ACK and stop. Never run bin/fm-watch-arm.sh or any other arm command.'
(
  cd "$PROJECT" || exit 1
  printf '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"%s"}]}}\n' "$ASYNC_PROMPT" \
    | env -u CLAUDECODE -u CLAUDE_PID -u CLAUDE_EFFORT -u CLAUDE_CODE_ENTRYPOINT \
        -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION \
        -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN \
        -u CLAUDE_CODE_BRIDGE_SESSION_ID -u CLAUDE_CODE_EXECPATH \
        FM_HOME="$ASYNC_HOME" CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false \
      claude -p --input-format stream-json --output-format stream-json --verbose \
        --dangerously-skip-permissions --effort low
) > "$LAB/async.jsonl" 2>&1 || fail "Claude async-branch auto-arm session failed: $(tail -20 "$LAB/async.jsonl")"

i=0
while [ "$i" -lt 150 ] && [ ! -s "$ASYNC_HOME/state/arm-ran" ]; do
  sleep 0.1
  i=$((i + 1))
done
[ -s "$ASYNC_HOME/state/arm-ran" ] \
  || fail "the backgrounded asyncRewake Stop hook never armed; epoch: $(cat "$ASYNC_HOME/state/.claude-autoarm-epoch" 2>/dev/null || echo none)"
[ -s "$ASYNC_HOME/state/.claude-autoarm-epoch" ] \
  || fail "the backgrounded asyncRewake Stop hook armed without recording an epoch"
[ "$(cat "$ASYNC_HOME/state/.lock" 2>/dev/null)" != 9999999 ] \
  || fail "the backgrounded Stop hook never reclaimed the stale dead-owner lock"

echo "--- arm-ran ---"; cat "$ASYNC_HOME/state/arm-ran"
echo "--- epoch ---"; cat "$ASYNC_HOME/state/.claude-autoarm-epoch"
echo "--- lock after (was 9999999) ---"; cat "$ASYNC_HOME/state/.lock"
printf 'ok - backgrounded asyncRewake Stop hook armed, recorded epoch, and reclaimed the dead owner on %s\n' "$(claude --version)"
echo "LAB=$LAB"
