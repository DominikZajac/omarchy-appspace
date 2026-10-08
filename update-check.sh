#!/bin/sh
# AppSpace update check. Read-only: it asks the plugin's own remote what its
# HEAD is and compares that with the installed commit. It never fetches, never
# writes into the checkout and never installs anything.
#
#   update-check.sh check <plugin-dir>   prints one word:
#       current     the installed commit is origin's HEAD, or ahead of it
#       available   origin has a commit this checkout does not contain
#       unmanaged   not a git checkout, so there is nothing to compare
#       unknown     offline, no origin, no git, or an answer that is not a commit id
#
#   update-check.sh apply <id> <plugin-dir>   run Omarchy's own updater, which
#       shows the diff and asks, then restart the shell if the plugin changed.
#       Meant to be run in a terminal.

# A commit id and nothing else: the remote's answer goes on to be an argument to
# other git commands, so it is checked against this shape first.
is_sha() { printf '%s' "$1" | grep -Eq '^[0-9a-f]{40}$'; }

check() {
  dir=$1
  [ -d "$dir/.git" ] || { echo unmanaged; return 0; }
  command -v git >/dev/null 2>&1 || { echo unknown; return 0; }
  export GIT_TERMINAL_PROMPT=0
  export GIT_SSH_COMMAND='ssh -oBatchMode=yes'

  local_head=$(git -C "$dir" rev-parse HEAD 2>/dev/null)
  is_sha "$local_head" || { echo unknown; return 0; }

  remote_head=$(timeout 15 git -C "$dir" ls-remote origin HEAD 2>/dev/null | cut -f1 | head -n 1)
  is_sha "$remote_head" || { echo unknown; return 0; }

  [ "$local_head" = "$remote_head" ] && { echo current; return 0; }

  # Different, so which way? Only objects already in the checkout are consulted:
  # a developer checkout that is ahead of origin must not be nagged.
  if git -C "$dir" cat-file -e "$remote_head^{commit}" 2>/dev/null &&
     git -C "$dir" merge-base --is-ancestor "$remote_head" "$local_head" 2>/dev/null; then
    echo current
  else
    echo available
  fi
}

apply() {
  id=$1
  dir=$2
  before=$(git -C "$dir" rev-parse HEAD 2>/dev/null)
  omarchy-plugin-update "$id"
  status=$?
  after=$(git -C "$dir" rev-parse HEAD 2>/dev/null)
  # A mounted widget keeps running the old code until the shell restarts.
  if [ -n "$after" ] && [ "$before" != "$after" ]; then
    omarchy restart shell
  fi
  return $status
}

case "$1" in
  check) check "$2" ;;
  apply) apply "$2" "$3" ;;
  *) echo "usage: update-check.sh check <dir> | apply <id> <dir>" >&2; exit 2 ;;
esac
