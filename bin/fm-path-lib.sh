#!/usr/bin/env bash
# Translate paths between the POSIX layer firstmate runs in and the native
# Windows forms its tools print, so a Windows-hosted repository can be driven
# from Git Bash/MSYS or WSL without ever mistaking one form for the other.
#
# Why this exists: on those hosts a pane, a native tool, or treehouse can
# answer with a drive-letter path (C:\Users\...\worktree) while every
# firstmate-side comparison and cd expects the POSIX form (/c/Users/... or
# /mnt/c/Users/...). Comparing or cd-ing the wrong form silently fails, and a
# silent failure at worktree-detection time is how a task falls back to the
# primary checkout and loses isolation.
#
# Contract:
#   fm_path_host           - print this environment's path host: msys | wsl | posix
#   fm_path_is_windows_form <path>
#                          - true when <path> is a drive-letter Windows form
#                            (C:\... or C:/...), the only form these helpers
#                            ever translate
#   fm_path_to_posix <path>
#                          - print the POSIX form of <path>. A path already in
#                            POSIX form passes through unchanged. A Windows
#                            form is translated with cygpath -u (MSYS) or
#                            wslpath -u (WSL); when no translator exists the
#                            call FAILS (returns 1) rather than guessing, so a
#                            caller can never act on an untranslated path.
#   fm_path_to_native <path>
#                          - print the native form a Windows-native tool needs:
#                            cygpath -w on MSYS, wslpath -w on WSL, unchanged
#                            passthrough on a purely POSIX host. Fails rather
#                            than guessing when the translator is missing.
#
# Both translators refuse empty input. Trailing CR (a cmd.exe/CRLF artifact in
# captured pane output) is stripped before classification so a captured
# Windows path never smuggles a carriage return into a recorded worktree path.

fm_path_host() {
  case "$(uname -s 2>/dev/null)" in
    MSYS*|MINGW*|CYGWIN*) echo msys ;;
    Linux)
      if [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/version 2>/dev/null; then
        echo wsl
      else
        echo posix
      fi
      ;;
    *) echo posix ;;
  esac
}

fm_path_strip_cr() {
  printf '%s' "$1" | tr -d '\r'
}

fm_path_is_windows_form() {
  case "$1" in
    [A-Za-z]:\\*|[A-Za-z]:/*) return 0 ;;
    *) return 1 ;;
  esac
}

fm_path_to_posix() {
  local path host
  path=$(fm_path_strip_cr "$1")
  [ -n "$path" ] || return 1
  if ! fm_path_is_windows_form "$path"; then
    printf '%s\n' "$path"
    return 0
  fi
  host=$(fm_path_host)
  case "$host" in
    msys)
      command -v cygpath >/dev/null 2>&1 || return 1
      cygpath -u -- "$path" 2>/dev/null
      ;;
    wsl)
      command -v wslpath >/dev/null 2>&1 || return 1
      wslpath -u -- "$path" 2>/dev/null
      ;;
    *)
      # A Windows-form path on a purely POSIX host has no meaningful
      # translation; refusing is the only answer that cannot mis-resolve.
      return 1
      ;;
  esac
}

fm_path_to_native() {
  local path host
  path=$(fm_path_strip_cr "$1")
  [ -n "$path" ] || return 1
  host=$(fm_path_host)
  case "$host" in
    msys)
      command -v cygpath >/dev/null 2>&1 || return 1
      cygpath -w -- "$path" 2>/dev/null
      ;;
    wsl)
      command -v wslpath >/dev/null 2>&1 || return 1
      wslpath -w -- "$path" 2>/dev/null
      ;;
    *)
      printf '%s\n' "$path"
      ;;
  esac
}
