#!/bin/bash
# Shared helper: resolve a git branch name to a GitHub issue number.
#
# Convention:
#   Branch "feat/my-feature" matches a GH issue with title containing "my-feature"
#   or with a label matching the branch name.
#   Searches open issues first, then all issues.
#
# Usage:
#   source "$(dirname "$0")/helpers/resolve_issue.sh"
#   ISSUE_NUM=$(resolve_gh_issue "$BRANCH_NAME")
#
# Outputs the matched issue number to stdout. Returns 1 if no match found.

resolve_gh_issue() {
  local branch="$1"

  # Strip prefix (feat/, fix/, refactor/, etc.)
  local slug="${branch#*/}"
  [ -z "$slug" ] && return 1

  # 1. Search open issues whose title contains the slug
  local num
  num=$(gh issue list --state open --search "$slug in:title" --json number --jq '.[0].number' 2>/dev/null)
  if [ -n "$num" ] && [ "$num" != "null" ]; then
    echo "$num"
    return 0
  fi

  # 2. Search all issues (including closed) whose title contains the slug
  num=$(gh issue list --state all --search "$slug in:title" --json number --jq '.[0].number' 2>/dev/null)
  if [ -n "$num" ] && [ "$num" != "null" ]; then
    echo "$num"
    return 0
  fi

  return 1
}
