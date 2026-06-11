#!/usr/bin/env bash
set -euo pipefail

SYNC_DIR=".codex-upstream-sync"
STATE_FILE="$SYNC_DIR/state.env"
PROMPT_FILE="$SYNC_DIR/prompt.md"

die() {
  echo "::error::$*" >&2
  exit 1
}

[[ -f "$STATE_FILE" ]] || die "Missing sync state file: $STATE_FILE"
# shellcheck source=/dev/null
source "$STATE_FILE"

mkdir -p "$SYNC_DIR"

{
  echo "# Task"
  echo
  echo "Resolve the current Git merge conflicts from syncing upstream into this repository."
  echo
  echo "# Context"
  echo
  echo "- Target branch: \`${TARGET_BRANCH:-}\`"
  echo "- Sync branch: \`${SYNC_BRANCH:-}\`"
  echo "- Upstream ref: \`${UPSTREAM_REF:-}\`"
  echo "- Upstream commit: \`${UPSTREAM_COMMIT:-}\`"
  echo
  echo "# Conflicted files"
  echo
  if [[ -s "$SYNC_DIR/conflicts.txt" ]]; then
    sed 's/^/- `/' "$SYNC_DIR/conflicts.txt" | sed 's/$/`/'
  else
    git diff --name-only --diff-filter=U | sed 's/^/- `/' | sed 's/$/`/'
  fi
  echo
  echo "# Requirements"
  echo
  echo "- Resolve only the merge conflicts introduced by this upstream sync."
  echo "- Preserve both sides when they are compatible."
  echo "- Do not refactor unrelated code."
  echo "- Do not create commits, branches, tags, pull requests, or pushes."
  echo "- Leave the working tree ready for \`git diff --check\` and the repository test command."
  echo "- If a conflict cannot be resolved safely, stop and explain the blocker."
  echo
  echo "# Useful commands"
  echo
  echo "\`\`\`bash"
  echo "git status --short"
  echo "git diff --name-only --diff-filter=U"
  echo "git diff --check"
  echo "\`\`\`"
} >"$PROMPT_FILE"

echo "Codex conflict prompt written to $PROMPT_FILE"
