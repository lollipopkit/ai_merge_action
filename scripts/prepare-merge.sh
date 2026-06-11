#!/usr/bin/env bash
set -euo pipefail

SYNC_DIR=".codex-upstream-sync"
STATE_FILE="$SYNC_DIR/state.env"
REMOTE_NAME="codex-upstream"

die() {
  echo "::error::$*" >&2
  exit 1
}

write_output() {
  local key="$1"
  local value="$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$key" "$value" >>"$GITHUB_OUTPUT"
  fi
}

require_input() {
  local name="$1"
  local value="$2"
  [[ -n "$value" ]] || die "Missing required input: $name"
}

sanitize_ref() {
  printf '%s' "$1" | tr -c '[:alnum:]._' '-' | sed -E 's/^-+//; s/-+$//; s/-+/-/g'
}

normalize_upstream_url() {
  local repository="$1"
  local token="$2"

  case "$repository" in
    /*|./*|../*|file://*|http://*|https://*|ssh://*|git@*)
      if [[ -n "$token" && "$repository" == https://github.com/* ]]; then
        printf 'https://x-access-token:%s@%s' "$token" "${repository#https://}"
      else
        printf '%s' "$repository"
      fi
      ;;
    *)
      if [[ -n "$token" ]]; then
        printf 'https://x-access-token:%s@github.com/%s.git' "$token" "$repository"
      else
        printf 'https://github.com/%s.git' "$repository"
      fi
      ;;
  esac
}

current_branch() {
  git symbolic-ref --quiet --short HEAD 2>/dev/null || true
}

checkout_target_branch() {
  local target_branch="$1"

  if git show-ref --verify --quiet "refs/heads/$target_branch"; then
    git switch "$target_branch" >/dev/null
    return
  fi

  if git show-ref --verify --quiet "refs/remotes/origin/$target_branch"; then
    git switch -c "$target_branch" "origin/$target_branch" >/dev/null
    return
  fi

  die "Target branch '$target_branch' does not exist locally or on origin"
}

main() {
  local upstream_repository="${INPUT_UPSTREAM_REPOSITORY:-}"
  local upstream_ref="${INPUT_UPSTREAM_REF:-main}"
  local upstream_token="${INPUT_UPSTREAM_TOKEN:-}"
  local target_branch="${INPUT_TARGET_BRANCH:-}"
  local mode="${INPUT_MODE:-pr}"
  local branch_prefix="${INPUT_BRANCH_PREFIX:-codex/upstream-sync}"
  local git_user_name="${INPUT_GIT_USER_NAME:-github-actions[bot]}"
  local git_user_email="${INPUT_GIT_USER_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"

  require_input upstream-repository "$upstream_repository"
  [[ "$mode" == "pr" || "$mode" == "push" ]] || die "Invalid mode '$mode'. Expected 'pr' or 'push'."
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "This action must run inside a Git repository"

  if [[ -n "$upstream_token" ]]; then
    echo "::add-mask::$upstream_token"
  fi

  if [[ -n "$(git status --porcelain)" ]]; then
    die "Working tree must be clean before upstream sync starts"
  fi

  if [[ -n "$(git ls-files "$SYNC_DIR")" ]]; then
    die "Repository already tracks $SYNC_DIR; cannot use it as the action state directory"
  fi

  target_branch="${target_branch:-$(current_branch)}"
  require_input target-branch "$target_branch"

  git config user.name "$git_user_name"
  git config user.email "$git_user_email"

  local upstream_url
  upstream_url="$(normalize_upstream_url "$upstream_repository" "$upstream_token")"

  if git remote get-url "$REMOTE_NAME" >/dev/null 2>&1; then
    git remote set-url "$REMOTE_NAME" "$upstream_url"
  else
    git remote add "$REMOTE_NAME" "$upstream_url"
  fi

  git fetch --no-tags origin "+refs/heads/$target_branch:refs/remotes/origin/$target_branch" >/dev/null 2>&1 || true
  git fetch --no-tags "$REMOTE_NAME" "+refs/heads/$upstream_ref:refs/remotes/$REMOTE_NAME/$upstream_ref"

  checkout_target_branch "$target_branch"

  local upstream_commit
  upstream_commit="$(git rev-parse "refs/remotes/$REMOTE_NAME/$upstream_ref")"

  if git merge-base --is-ancestor "$upstream_commit" HEAD; then
    write_output changed false
    write_output needs_codex false
    write_output merge_status up-to-date
    write_output branch ""
    exit 0
  fi

  local safe_target
  local short_sha
  local run_id
  safe_target="$(sanitize_ref "$target_branch")"
  short_sha="${upstream_commit:0:12}"
  run_id="${GITHUB_RUN_ID:-local}-$(date -u +%Y%m%d%H%M%S)"
  local sync_branch="$branch_prefix/$safe_target-$short_sha-$run_id"

  git switch -c "$sync_branch" >/dev/null

  set +e
  git merge --no-commit --no-ff "$upstream_commit"
  local merge_code=$?
  set -e

  mkdir -p "$SYNC_DIR"
  {
    printf 'MODE=%q\n' "$mode"
    printf 'TARGET_BRANCH=%q\n' "$target_branch"
    printf 'SYNC_BRANCH=%q\n' "$sync_branch"
    printf 'UPSTREAM_COMMIT=%q\n' "$upstream_commit"
    printf 'UPSTREAM_REF=%q\n' "$upstream_ref"
  } >"$STATE_FILE"

  write_output changed true
  write_output branch "$sync_branch"

  if [[ "$merge_code" -eq 0 ]]; then
    write_output needs_codex false
    write_output merge_status clean
    exit 0
  fi

  if [[ -n "$(git diff --name-only --diff-filter=U)" ]]; then
    write_output needs_codex true
    write_output merge_status conflict
    git diff --name-only --diff-filter=U >"$SYNC_DIR/conflicts.txt"
    exit 0
  fi

  die "git merge failed without unresolved conflict files"
}

main "$@"
