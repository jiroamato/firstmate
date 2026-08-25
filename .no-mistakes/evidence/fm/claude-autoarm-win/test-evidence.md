# Test evidence: Claude session identity from the published session pid (fm/claude-autoarm-win)

Host: Windows 11, Git Bash (MSYS), real Claude Code 2.1.243. Change under test:
`1f4fc93` "fix(session-lock): resolve Claude session identity from the published
session pid" over base `35505b5`.

## 1. Live end-to-end: the backgrounded asyncRewake Stop hook now arms (the reported broken path)

Standalone run of the async phase the change added to
`tests/fm-claude-stop-autoarm-live-e2e.test.sh` (see `async-live-driver.sh`,
which mirrors it verbatim): a real `claude -p --input-format stream-json`
session in an isolated project carrying the UNCHANGED tracked compound
`asyncRewake: true` Stop registration, with an isolated FM_HOME seeded with a
dead 9999999 lock owner and one task in flight. This is the branch a real
interactive fleet session takes, and the exact path reported as "never fires"
on Windows.

Result: PASS.

```
--- state/arm-ran ---
arm-run=1 pid=802286
arm-run=2 pid=803188
arm-run=3 pid=803963
arm-run=4 pid=804085
--- state/.claude-autoarm-epoch ---
epoch=6 owner_pid=803438 outcome=clean updated_at=1787620044
--- state/.lock (seeded as 9999999 dead owner) ---
17640
ok - backgrounded asyncRewake Stop hook armed, recorded epoch, and reclaimed the dead owner on 2.1.243 (Claude Code)
```

The hook-owned watcher arm fixture ran four times with zero model-issued arm
commands (the model only ever answered `CYCLE0`/`ACK`; final transcript results
are `"result":"ACK"`), the auto-arm epoch ledger was written, the dead 9999999
owner was reclaimed to the live session pid, and `task.meta` was drained by the
third arm cycle as the fixture designs. Full session transcript:
`async-live-transcript.jsonl`. Before the fix this exact scenario produced no
arm, no epoch, and no reclaim (the hook exited inert at its identity gate);
the library-level red run below shows the broken gate directly.

## 2. Regression suite, fixed library (worktree): unit layer fully green

`bash tests/fm-session-lock-ancestry.test.sh` at `1f4fc93`:

```
ok - session-lock: a version-named Claude Code session is identified from its install path and argv[0]
ok - session-lock: ordinary script paths under a harness directory are not harness processes
ok - session-lock: a severed process-tree walk still resolves identity from the pid the harness published
ok - session-lock: a published session pid is rejected unless it is live, a verified harness, and the lock holder
ok - session-lock: a walk that resolves on its own keeps deciding identity, gap protection included
ok - session-lock: ownership stops at the first non-harness gap above the contiguous run
ok - session-lock: a live version-named session holding the lock is not mistaken for a stale owner
not ok - the fixture hook never finished
```

All seven unit-layer cases pass, including the three new severed-walk /
untrusted-pid / walk-still-decides cases and their divergence guard, and the
pre-existing gap-protection and competing-owner cases are unregressed. The
final `not ok` is the file's END-TO-END fixture layer, which fails on this
Windows host independently of this change - confirmed in section 4.

## 3. Red baseline: the new regression case fails on the unfixed library

Same test file run in a scratch tree whose `bin/fm-session-lock-lib.sh` is the
BASE commit's copy (`git show 35505b5:bin/fm-session-lock-lib.sh`; it contains
no `fm_harness_env_session_pid`):

```
ok - session-lock: a version-named Claude Code session is identified from its install path and argv[0]
ok - session-lock: ordinary script paths under a harness directory are not harness processes
not ok - a session whose walk is severed did not recognize the lock its own harness published
```

The new coverage fails on the broken path with the exact defect the incident
reported (a severed walk leaves the session unable to recognize its own lock),
and passes after the fix - a genuine red-before/green-after regression test.

## 4. Pre-existing e2e-layer failure confirmed independent of this change

Running only `test_e2e_version_named_session_claims_the_home` in the same
base-library scratch tree reproduces the identical failure against code that
predates the change entirely, matching the intent's disclosure:

```
not ok - the fixture hook never finished
```

## 5. Corroboration of the mechanism

`CLAUDE_PID` was observed published in this very validation session's own
tool-call environment (Claude Code exports it to hook commands and tool
calls), which is the capability - not uname - the fix keys on.
