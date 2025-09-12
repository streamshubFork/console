#!/usr/bin/env bash
set -xeuo pipefail

# Returns empty edit mode if the last bot comment is NOT the help message
getEditModeIfLastCommentIsHelp() {
  local marker="ℹ️ Systemtests Help ℹ️"
  local edit_existing=${1:-false}
  local comment_author=$(gh api user --jq '.login')

  local last_body=$(gh pr view "$PR_NUMBER" --repo "$REPO" \
    --json comments \
    --jq '.comments
          | map(select(.author.login=="'"$comment_author"'"))
          | sort_by(.updatedAt)
          | last
          | .body // empty')

  if [[ -n $last_body && $edit_existing == "true" && $last_body == *"$marker"* ]]; then
    echo "--edit-last --create-if-none"
  else
    echo ""
  fi
}
