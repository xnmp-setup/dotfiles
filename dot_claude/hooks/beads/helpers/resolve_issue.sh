#!/bin/bash
# Shared helper: resolve a git branch name to a Beads issue ID.
#
# Convention:
#   Branch "feat/myfeature" matches issue ID "feat/myfeature" (exact)
#   OR issue ID "feat-myfeature-<hash>" (slug prefix match)
#
# Usage:
#   source "$(dirname "$0")/helpers/resolve_issue.sh"
#   ISSUE_ID=$(resolve_beads_issue "$BRANCH_NAME")
#
# Outputs the matched issue ID to stdout. Returns 1 if no match found.

resolve_beads_issue() {
  local branch="$1"

  # 1. Exact match (backward compat)
  if bd show "$branch" --json &>/dev/null; then
    echo "$branch"
    return 0
  fi

  # 2. Slug prefix match: feat/foo → feat-foo-*
  local slug="${branch//\//-}"
  local match
  match=$(bd list --all --json 2>/dev/null \
    | jq -r --arg pfx "$slug-" '[.[] | select(.id | startswith($pfx))] | sort_by(.created_at) | reverse | .[0].id // empty')

  if [ -n "$match" ]; then
    echo "$match"
    return 0
  fi

  return 1
}
