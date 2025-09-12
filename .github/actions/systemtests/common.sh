#!/usr/bin/env bash
set -xeuo pipefail

# Returns edit mode if the last bot comment contains string
getCommentMode() {
  local marker=$1
  local edit_existing=${2:-false}
  local comment_author=$(gh api user --jq '.login')

  local last_body=$(gh pr view "$PR_NUMBER" --repo "$REPO" \
    --json comments \
    --jq '.comments
          | map(select(.author.login=="'"$comment_author"'"))
          | sort_by(.updatedAt)
          | last
          | .body // empty')

  if [[ -n $last_body && -n $marker && $edit_existing == "true" && $last_body == *"$marker"* ]]; then
    echo "--edit-last --create-if-none"
  else
    echo ""
  fi
}
