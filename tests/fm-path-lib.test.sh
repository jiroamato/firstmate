#!/usr/bin/env bash
# Behavior tests for bin/fm-path-lib.sh - Windows/POSIX path translation.
#
# The library must classify drive-letter Windows forms, pass POSIX paths
# through untouched, translate through cygpath/wslpath when the host provides
# one, and FAIL rather than guess when a Windows form cannot be translated.
# These tests run on any POSIX host by shimming cygpath/wslpath and the host
# classification inputs; no real Windows host is required.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-path-lib.sh
. "$ROOT/bin/fm-path-lib.sh"

# --- fm_path_is_windows_form -------------------------------------------------

fm_path_is_windows_form 'C:\Users\jk\.treehouse\aim-59788f\1\aim' \
  || fail "backslash drive form not recognized as windows form"
fm_path_is_windows_form 'c:/Users/jk/work' \
  || fail "forward-slash drive form not recognized as windows form"
! fm_path_is_windows_form '/c/Users/jk/work' \
  || fail "MSYS posix form misread as windows form"
! fm_path_is_windows_form '/mnt/c/Users/jk/work' \
  || fail "WSL posix form misread as windows form"
! fm_path_is_windows_form 'relative/path' \
  || fail "relative path misread as windows form"
pass "windows-form classification separates drive-letter forms from posix forms"

# --- fm_path_to_posix passthrough and refusal --------------------------------

out=$(fm_path_to_posix '/home/user/project') || fail "posix path did not pass through"
[ "$out" = '/home/user/project' ] || fail "posix passthrough altered the path: $out"
pass "a posix path passes through fm_path_to_posix unchanged"

# CR stripping: a captured cmd.exe line ends in \r; the translated output must not.
out=$(fm_path_to_posix $'/home/user/project\r') || fail "CR-suffixed posix path rejected"
[ "$out" = '/home/user/project' ] || fail "CR survived translation: $(printf '%q' "$out")"
pass "a trailing carriage return is stripped before classification"

! fm_path_to_posix '' 2>/dev/null || fail "empty input must fail"
pass "empty input is refused"

# On a purely POSIX host (no cygpath/wslpath reachable, no WSL markers), a
# Windows form must FAIL loudly instead of echoing through.
if [ "$(fm_path_host)" = posix ]; then
  ! fm_path_to_posix 'C:\Users\jk\work' 2>/dev/null \
    || fail "windows form must not translate on a posix host"
  pass "a windows form fails rather than guessing on a posix host"
else
  pass "skip: host is not posix, refusal case exercised by shim below"
fi

# --- translation through a shimmed cygpath -----------------------------------

FAKEBIN=$(mktemp -d)
trap 'rm -rf "$FAKEBIN"' EXIT
cat > "$FAKEBIN/cygpath" <<'EOF'
#!/usr/bin/env bash
# Minimal cygpath -u shim: C:\a\b -> /c/a/b
mode=$1; shift
[ "$mode" = -u ] || [ "$mode" = -w ] || exit 2
[ "$1" = -- ] && shift
p=$1
if [ "$mode" = -u ]; then
  drive=$(printf '%s' "$p" | cut -c1 | tr '[:upper:]' '[:lower:]')
  rest=$(printf '%s' "$p" | cut -c3- | tr '\\' '/')
  printf '/%s%s\n' "$drive" "$rest"
else
  printf 'C:\\shimmed\\%s\n' "$(basename "$p")"
fi
EOF
chmod 755 "$FAKEBIN/cygpath"

# Force the msys branch by overriding uname through a shim as well.
cat > "$FAKEBIN/uname" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -s ]; then echo MINGW64_NT-10.0; else echo MINGW64_NT-10.0; fi
EOF
chmod 755 "$FAKEBIN/uname"

out=$(PATH="$FAKEBIN:$PATH" bash -c '
  . "$1/bin/fm-path-lib.sh"
  fm_path_to_posix "C:\Users\jk\.treehouse\aim-59788f\1\aim"
' _ "$ROOT") || fail "msys translation failed"
[ "$out" = '/c/Users/jk/.treehouse/aim-59788f/1/aim' ] \
  || fail "msys translation wrong: $out"
pass "a windows form translates through cygpath on an msys host"

# Missing translator on a claimed msys host: must fail, never echo through.
out=$(PATH="$FAKEBIN:$PATH" bash -c '
  rm -f "$2/cygpath"
  . "$1/bin/fm-path-lib.sh"
  if fm_path_to_posix "C:\Users\jk\work" 2>/dev/null; then echo LEAKED; fi
' _ "$ROOT" "$FAKEBIN")
[ "$out" != LEAKED ] || fail "windows form leaked through without a translator"
pass "a missing translator refuses instead of passing the windows form through"

echo "fm-path-lib: all tests passed"
