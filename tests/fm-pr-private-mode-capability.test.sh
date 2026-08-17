#!/usr/bin/env bash
# Behavior tests for fm_pr_private_file_valid's capability-probed Windows
# branch (bin/fm-pr-lib.sh + bin/fm-state-capability-lib.sh, the probe adopted
# from upstream PR #2378).
#
# The old branch keyed the owner-check substitution on uname alone, so an acl
# MSYS mount that CAN hold POSIX modes was silently held to the weaker owner
# check. Now the filesystem answers for itself: where the behavioral probe
# proves owner-only modes, Windows keeps the strict mode requirement; only a
# provably mode-incapable filesystem falls back to the owner match.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORLD=$(fm_test_tmproot fm-pr-private-mode)
STATE="$WORLD/state"
mkdir -p "$STATE"

# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"

DEVICE=$(fm_pr_file_device "$STATE")

make_private() { # <name> <mode>
  local f="$STATE/$1"
  : > "$f"
  chmod "$2" "$f"
  printf '%s\n' "$f"
}

# --- POSIX host: strict mode check, unchanged --------------------------------

f=$(make_private posix-600 600)
fm_pr_private_file_valid "$f" 600 "$DEVICE" || fail "0600 file must validate on a posix host"
f=$(make_private posix-644 644)
fm_pr_private_file_valid "$f" 600 "$DEVICE" && fail "0644 file must not validate on a posix host"
pass "the posix strict mode check is unchanged"

# --- claimed-Windows host on a mode-capable filesystem -----------------------

# Shim uname to claim MINGW64 while the real filesystem (this test host)
# provably CAN hold owner-only modes; the strict check must stay in force.
FAKEBIN="$WORLD/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/uname" <<'SH'
#!/usr/bin/env bash
echo MINGW64_NT-10.0
SH
chmod 755 "$FAKEBIN/uname"

run_msys() { # <file> <mode>
  PATH="$FAKEBIN:$PATH" bash -c '
    . "$1/bin/fm-pr-lib.sh"
    fm_pr_private_file_valid "$2" 600 "$3"
  ' _ "$ROOT" "$1" "$DEVICE"
}

f=$(make_private msys-600 600)
run_msys "$f" || fail "0600 file must validate on a mode-capable Windows filesystem"
f=$(make_private msys-644 644)
run_msys "$f" && fail "a mode-capable Windows filesystem must keep the strict check and reject 0644"
pass "a mode-capable filesystem keeps the strict mode check even under a Windows uname"

# --- claimed-Windows host on a mode-incapable filesystem ---------------------

# Force the probe to fail (mktemp refused, as on a filesystem that cannot host
# the probe) so capability resolves data-only; the owner match then carries
# the requirement, and a wrong-mode-but-owned file is accepted.
cat > "$FAKEBIN/mktemp" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod 755 "$FAKEBIN/mktemp"

f=$(make_private msys-noacl-644 644)
run_msys "$f" || fail "a provably mode-incapable filesystem must fall back to the owner match"
pass "a provably mode-incapable filesystem substitutes the owner match"

rm -f "$FAKEBIN/mktemp"

echo "fm-pr-private-mode-capability: all tests passed"
