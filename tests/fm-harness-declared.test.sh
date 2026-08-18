#!/usr/bin/env bash
# Behavior tests for fm-harness.sh's layer-0 declared identity
# (FM_HARNESS_DECLARED), the supported fallback for hosts whose process tree
# cannot testify (#2307 upstream: WSL2 re-parents Herdr-launched shells to
# pid 1, so ancestry never finds the harness and detection returned unknown).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
WORLD=$(fm_test_tmproot fm-harness-declared)

# A declared verified adapter wins over every other layer, including an
# inherited CLAUDECODE marker.
out=$(FM_HARNESS_DECLARED=codex CLAUDECODE=1 "$HARNESS")
[ "$out" = codex ] || fail "declared codex should outrank the CLAUDECODE marker, got: $out"
pass "a declared verified adapter outranks an inherited env marker"

out=$(FM_HARNESS_DECLARED=pi-signed "$HARNESS")
[ "$out" = pi-signed ] || fail "declared pi-signed not honored, got: $out"
pass "every verified adapter name is accepted as declared identity"

# An unverified name is ignored with a warning, and detection continues to
# the next layer instead of inventing a harness.
out=$(FM_HARNESS_DECLARED=cursor CLAUDECODE=1 "$HARNESS" 2>"$WORLD/declared-warn" || true)
warn=$(cat "$WORLD/declared-warn" 2>/dev/null)
[ "$out" = claude ] || fail "an unverified declared name must fall through to markers, got: $out"
case "$warn" in
  *"ignoring FM_HARNESS_DECLARED"*) : ;;
  *) fail "an ignored declaration must warn on stderr, got: $warn" ;;
esac
pass "an unverified declared name is ignored loudly and detection falls through"

# An empty declaration behaves exactly as before the knob existed.
out=$(FM_HARNESS_DECLARED='' CLAUDECODE=1 "$HARNESS")
[ "$out" = claude ] || fail "empty declaration changed marker detection, got: $out"
pass "an empty declaration leaves marker detection untouched"

echo "fm-harness-declared: all tests passed"
