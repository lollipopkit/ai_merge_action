#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local expected="$2"
  grep -Fq "$expected" "$file" || fail "Expected '$expected' in $file"
}

git_init_repo() {
  local path="$1"
  mkdir -p "$path"
  git -C "$path" init -q
  git -C "$path" config user.name "Test User"
  git -C "$path" config user.email "test@example.com"
}

commit_file() {
  local repo="$1"
  local file="$2"
  local content="$3"
  local message="$4"
  mkdir -p "$(dirname "$repo/$file")"
  printf '%s\n' "$content" >"$repo/$file"
  git -C "$repo" add "$file"
  git -C "$repo" commit -q -m "$message"
}

setup_repos() {
  local name="$1"
  local scenario_dir="$TMP_ROOT/$name"
  local seed="$scenario_dir/seed"
  local upstream_work="$scenario_dir/upstream-work"
  local origin_bare="$scenario_dir/origin.git"
  local upstream_bare="$scenario_dir/upstream.git"
  local work="$scenario_dir/work"

  mkdir -p "$scenario_dir"
  git_init_repo "$seed"
  commit_file "$seed" "README.md" "base" "initial"
  git -C "$seed" branch -M main

  git clone -q --bare "$seed" "$origin_bare"
  git clone -q --bare "$seed" "$upstream_bare"
  git clone -q "$origin_bare" "$work"
  git -C "$work" switch -q main
  git -C "$work" config user.name "Target User"
  git -C "$work" config user.email "target@example.com"

  git clone -q "$upstream_bare" "$upstream_work"
  git -C "$upstream_work" switch -q main
  git -C "$upstream_work" config user.name "Upstream User"
  git -C "$upstream_work" config user.email "upstream@example.com"

  printf '%s\n' "$scenario_dir"
}

run_prepare() {
  local work="$1"
  local upstream="$2"
  local mode="${3:-push}"
  local output_file
  output_file="$(dirname "$work")/prepare.out"
  (
    cd "$work"
    GITHUB_OUTPUT="$output_file" \
    INPUT_UPSTREAM_REPOSITORY="$upstream" \
    INPUT_UPSTREAM_REF="main" \
    INPUT_UPSTREAM_TOKEN="" \
    INPUT_TARGET_BRANCH="main" \
    INPUT_MODE="$mode" \
    INPUT_BRANCH_PREFIX="codex/upstream-sync" \
    INPUT_GIT_USER_NAME="Test Bot" \
    INPUT_GIT_USER_EMAIL="bot@example.com" \
      bash "$ROOT_DIR/scripts/prepare-merge.sh"
  )
}

run_finalize() {
  local work="$1"
  local mode="${2:-push}"
  local output_file
  output_file="$(dirname "$work")/finalize.out"
  (
    cd "$work"
    GITHUB_OUTPUT="$output_file" \
    INPUT_GITHUB_TOKEN="dummy-token" \
    INPUT_TEST_COMMAND="git status --short" \
    INPUT_COMMIT_MESSAGE="chore: sync upstream" \
    INPUT_UPSTREAM_REPOSITORY="../upstream.git" \
    INPUT_UPSTREAM_REF="main" \
      bash "$ROOT_DIR/scripts/finalize.sh"
  )
}

test_noop_when_up_to_date() {
  local scenario work upstream
  scenario="$(setup_repos noop)"
  work="$scenario/work"
  upstream="$scenario/upstream.git"

  run_prepare "$work" "$upstream"
  assert_contains "$scenario/prepare.out" "changed=false"
  assert_contains "$scenario/prepare.out" "merge_status=up-to-date"
}

test_clean_merge_push() {
  local scenario work upstream upstream_work
  scenario="$(setup_repos clean)"
  work="$scenario/work"
  upstream="$scenario/upstream.git"
  upstream_work="$scenario/upstream-work"

  commit_file "$upstream_work" "upstream.txt" "from upstream" "upstream change"
  git -C "$upstream_work" push -q origin main

  run_prepare "$work" "$upstream"
  assert_contains "$scenario/prepare.out" "changed=true"
  assert_contains "$scenario/prepare.out" "needs_codex=false"
  assert_contains "$scenario/prepare.out" "merge_status=clean"

  run_finalize "$work"
  assert_contains "$scenario/finalize.out" "merge_status=pushed"

  git -C "$work" fetch -q origin main
  git -C "$work" merge-base --is-ancestor HEAD origin/main || fail "origin/main was not updated"
  ! git -C "$work" ls-tree -r --name-only HEAD | grep -Fq ".codex-upstream-sync" || fail "sync temp files were committed"
}

test_conflict_then_manual_resolution() {
  local scenario work upstream upstream_work
  scenario="$(setup_repos conflict)"
  work="$scenario/work"
  upstream="$scenario/upstream.git"
  upstream_work="$scenario/upstream-work"

  commit_file "$work" "README.md" "target change" "target change"
  git -C "$work" push -q origin main
  commit_file "$upstream_work" "README.md" "upstream change" "upstream change"
  git -C "$upstream_work" push -q origin main

  run_prepare "$work" "$upstream"
  assert_contains "$scenario/prepare.out" "changed=true"
  assert_contains "$scenario/prepare.out" "needs_codex=true"
  assert_contains "$scenario/prepare.out" "merge_status=conflict"

  (
    cd "$work"
    bash "$ROOT_DIR/scripts/build-codex-prompt.sh"
    printf '%s\n' "target change" "upstream change" >README.md
    git add README.md
  )

  run_finalize "$work"
  assert_contains "$scenario/finalize.out" "merge_status=pushed"
  ! git -C "$work" ls-tree -r --name-only HEAD | grep -Fq ".codex-upstream-sync" || fail "sync temp files were committed"
}

test_pr_mode_uses_gh() {
  local scenario work upstream upstream_work mock_bin
  scenario="$(setup_repos pr)"
  work="$scenario/work"
  upstream="$scenario/upstream.git"
  upstream_work="$scenario/upstream-work"
  mock_bin="$scenario/bin"
  mkdir -p "$mock_bin"
  cat >"$mock_bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "pr" && "${2:-}" == "create" ]]; then
  echo "https://github.com/example/repo/pull/1"
  exit 0
fi
echo "unexpected gh invocation: $*" >&2
exit 1
GH
  chmod +x "$mock_bin/gh"

  commit_file "$upstream_work" "pr.txt" "pr mode" "pr change"
  git -C "$upstream_work" push -q origin main

  run_prepare "$work" "$upstream" "pr"
  (
    cd "$work"
    PATH="$mock_bin:$PATH" \
    GITHUB_OUTPUT="$scenario/finalize.out" \
    INPUT_GITHUB_TOKEN="dummy-token" \
    INPUT_TEST_COMMAND="" \
    INPUT_COMMIT_MESSAGE="chore: sync upstream" \
    INPUT_UPSTREAM_REPOSITORY="../upstream.git" \
    INPUT_UPSTREAM_REF="main" \
      bash "$ROOT_DIR/scripts/finalize.sh"
  )
  assert_contains "$scenario/finalize.out" "merge_status=pr"
  assert_contains "$scenario/finalize.out" "pr_url=https://github.com/example/repo/pull/1"
  ! git -C "$work" ls-tree -r --name-only HEAD | grep -Fq ".codex-upstream-sync" || fail "sync temp files were committed"
}

test_resolve_codex_endpoint() {
  local output_file="$TMP_ROOT/endpoint.out"

  GITHUB_OUTPUT="$output_file" INPUT_OPENAI_BASE_URL="" bash "$ROOT_DIR/scripts/resolve-codex-endpoint.sh"
  assert_contains "$output_file" "responses-api-endpoint="

  : >"$output_file"
  GITHUB_OUTPUT="$output_file" INPUT_OPENAI_BASE_URL="https://proxy.example.com/v1" bash "$ROOT_DIR/scripts/resolve-codex-endpoint.sh"
  assert_contains "$output_file" "responses-api-endpoint=https://proxy.example.com/v1/responses"

  : >"$output_file"
  GITHUB_OUTPUT="$output_file" INPUT_OPENAI_BASE_URL="https://proxy.example.com/v1/" bash "$ROOT_DIR/scripts/resolve-codex-endpoint.sh"
  assert_contains "$output_file" "responses-api-endpoint=https://proxy.example.com/v1/responses"

  : >"$output_file"
  GITHUB_OUTPUT="$output_file" INPUT_OPENAI_BASE_URL="https://proxy.example.com/v1/responses" bash "$ROOT_DIR/scripts/resolve-codex-endpoint.sh"
  assert_contains "$output_file" "responses-api-endpoint=https://proxy.example.com/v1/responses"
}

test_noop_when_up_to_date
test_clean_merge_push
test_conflict_then_manual_resolution
test_pr_mode_uses_gh
test_resolve_codex_endpoint

echo "All tests passed"
