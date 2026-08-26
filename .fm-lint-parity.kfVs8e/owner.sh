#!/usr/bin/env bash
# shellcheck source=.fm-lint-parity.kfVs8e/owner-dep.sh
. "/c/Users/amato/.no-mistakes/worktrees/ee8de15012e3/01M0Z1SMZX96F1K7Q0EHZE23KR/.fm-lint-parity.kfVs8e/owner-dep.sh"
owner_bad() {
  printf '%s\n' "$owner_dependency_value"
  cd "$1"
}
