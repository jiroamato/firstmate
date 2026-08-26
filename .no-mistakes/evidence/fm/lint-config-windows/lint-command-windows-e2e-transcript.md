# E2E evidence: pinned lint command is runnable on Windows via cmd.exe

Host: Windows 11, Git Bash at `C:\Program Files\Git\usr\bin`, ShellCheck at
`C:\Users\amato\bin\shellcheck.exe`. All commands below were executed inside the
no-mistakes gate worktree with the PATH inherited from the no-mistakes pipeline
process itself (the same environment the daemon hands to `cmd /C`), where
`C:\Program Files\Git\usr\bin` precedes `C:\WINDOWS\system32`:

```
> cmd /c "where bash"
C:\Program Files\Git\usr\bin\bash.exe
C:\Windows\System32\bash.exe
C:\Users\amato\AppData\Local\Microsoft\WindowsApps\bash.exe
```

## 1. Reproduction: the OLD pinned command (`bin/fm-lint.sh`) dies under cmd.exe

```
> cmd /c "bin/fm-lint.sh"
'bin' is not recognized as an internal or external command,
operable program or batch file.
EXIT=1
```

This is verbatim the failure text recorded on the prior runs (PRs 6 and 7):
cmd.exe cannot exec a POSIX script path, regardless of PATH contents.

## 2. Fix: the NEW pinned command (`bash bin/fm-lint.sh`) runs the lint owner end-to-end

```
> cmd /c "bash bin/fm-lint.sh"
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
EXIT=0
```

The single lint owner `bin/fm-lint.sh` (untouched by this change) runs, resolves
the pinned ShellCheck 0.11.0, lints its full canonical file set, and exits 0.

## 3. LF pin: a fresh `core.autocrlf=true` checkout keeps the lint surface CRLF-free

Simulated a fresh Windows checkout with
`git -c core.autocrlf=true checkout-index --prefix=<tmp>/ -a`, then scanned the
checked-out files for CR (0x0D) bytes:

```
sh files checked: 200
files containing CR: 0
control non-sh file AGENTS.md contains CR (autocrlf active): True
```

The control `.md` file DID receive CRLF, proving autocrlf was genuinely active in
the simulation; every `.sh` file stayed LF because of the new
`.gitattributes` pin (`*.sh text eol=lf`). Without the pin, ShellCheck 0.11.0
reports SC1017 on every line of a CRLF checkout.

## 4. Regression guards: fail before the fix, pass after it

The new `test_gate_pins_the_owner_behind_an_interpreter` guard, run against the
base-commit (pre-fix) `.no-mistakes.yaml` in a hermetic temp root:

```
not ok - commands.lint must name an interpreter first so cmd.exe can exec it; got 'bin/fm-lint.sh'
EXIT=1
```

Against the fixed config (and in the full suite below) the same guard passes.

## 5. Gate parity test suite (`tests/fm-lint.test.sh`)

Full suite run on this Windows host, all 16 tests green including the two new
guards:

```
ok - fm-lint.sh --list-files reports the complete shell inventory
ok - fm-lint.sh pins an explicit ShellCheck version (0.11.0)
ok - ShellCheck installer retries a transient download failure
ok - fm-lint.sh refuses to lint under a non-pinned ShellCheck version
ok - fm-lint.sh catches a real lint defect the old no-op gate passed
ok - fm-lint.sh ignores ambient ShellCheck options
ok - fm-lint.sh passes a clean fixture
ok - jobs=1 and jobs=2 preserve deterministic diagnostics, failures, cleanup bounds, and quiet telemetry
ok - jobs=1 and jobs=2 stop complete worker trees with and without telemetry
ok - seeded dispatcher, adapter, production-owner, and test-local diagnostics preserve parity
ok - fm-lint.sh changed mode lints only the changed canonical file
ok - fm-lint.sh forces a full lint in CI even when the local diff would be empty
ok - fm-lint.sh forces a full lint when HEAD is on main
ok - fm-lint.sh explicit paths bypass changed-file mode selection
ok - fm-lint.sh exits 0 with a note when the local branch has no changed lint targets
ok - fm-lint.sh --list-files reports the would-be changed set in changed mode
ok - the no-mistakes gate pins bin/fm-lint.sh behind bash, so cmd.exe can exec it
ok - every lint target is pinned to LF, so no checkout can fail the gate on SC1017
EXIT=0
```

`bin/fm-lint.sh` itself is untouched by this change (verified in the
base..target diff), so the lint definition - file set, config, and pinned
ShellCheck 0.11.0 - is unchanged; only the invocation and checkout encoding
were fixed.

## 6. PATH-order footnote

With an artificial PATH that puts `C:\WINDOWS\system32` before Git's `usr/bin`,
`bash` resolves to the WSL launcher (`C:\Windows\System32\bash.exe`) instead of
Git Bash, and WSL's bash does not see `C:\Users\amato\bin` shellcheck:

```
> cmd /c "bash -c 'command -v shellcheck'"   # System32 first on PATH
NOT-FOUND (WSL bash, PATH=/usr/...:/mnt/c/Windows/System32:...)
```

The real pipeline environment orders Git's `usr/bin` first (transcript at top),
so the pinned command resolves Git Bash as intended. Recorded here because the
fix depends on `bash` resolving through the daemon's PATH, which the author
verified and this run re-confirmed.
