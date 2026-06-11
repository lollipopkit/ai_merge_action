# Codex Upstream Sync Action

Reusable GitHub Action for syncing an upstream repository branch into your repository. It performs the normal Git merge deterministically and invokes Codex only when merge conflicts need repair.

The default delivery mode opens a pull request. You can opt into direct push with `mode: push`.

## Usage

```yaml
name: Sync upstream

on:
  workflow_dispatch:
  schedule:
    - cron: "17 3 * * *"

permissions:
  contents: write
  pull-requests: write

jobs:
  sync:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
        with:
          fetch-depth: 0

      - uses: owner/ai_merge_action@v1
        with:
          openai-api-key: ${{ secrets.OPENAI_API_KEY }}
          # openai-base-url: https://api.openai.com/v1
          github-token: ${{ github.token }}
          upstream-repository: upstream-owner/upstream-repo
          upstream-ref: main
          target-branch: main
          mode: pr
          test-command: make test
```

For direct pushes, set `mode: push` and remove `pull-requests: write` if you do not need it:

```yaml
permissions:
  contents: write

jobs:
  sync:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
        with:
          fetch-depth: 0

      - uses: owner/ai_merge_action@v1
        with:
          openai-api-key: ${{ secrets.OPENAI_API_KEY }}
          github-token: ${{ github.token }}
          upstream-repository: upstream-owner/upstream-repo
          mode: push
```

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `openai-api-key` | Yes | | OpenAI API key used by `openai/codex-action@v1` when conflicts need Codex. |
| `openai-base-url` | No | | Optional OpenAI-compatible base URL, such as `https://proxy.example.com/v1`. The action appends `/responses` for `openai/codex-action@v1`. |
| `github-token` | Yes | | GitHub token used for push and PR creation. |
| `upstream-repository` | Yes | | Upstream repository as `owner/repo`, HTTPS URL, SSH URL, `file://` URL, or local path. |
| `upstream-ref` | No | `main` | Upstream branch to merge. |
| `upstream-token` | No | | Optional token for private GitHub upstream repositories. |
| `target-branch` | No | checked-out branch | Branch to sync into. |
| `mode` | No | `pr` | Delivery mode: `pr` or `push`. |
| `test-command` | No | | Command to run after the merge is resolved and before delivery. |
| `commit-message` | No | `chore: sync upstream` | Merge commit message. |
| `branch-prefix` | No | `codex/upstream-sync` | Prefix for PR sync branches. |
| `git-user-name` | No | `github-actions[bot]` | Git author name. |
| `git-user-email` | No | `41898282+github-actions[bot]@users.noreply.github.com` | Git author email. |
| `codex-model` | No | | Optional model passed to `openai/codex-action@v1`. |
| `codex-effort` | No | | Optional reasoning effort passed to `openai/codex-action@v1`. |
| `codex-args` | No | | Extra `codex exec` arguments passed through `openai/codex-action@v1`. |
| `sandbox` | No | `workspace-write` | Codex sandbox mode for conflict repair. |

## Outputs

| Output | Description |
| --- | --- |
| `changed` | `true` when upstream sync produced a merge change. |
| `codex-used` | `true` when Codex was invoked to repair conflicts. |
| `merge-status` | `up-to-date`, `clean`, `conflict`, `pushed`, or `pr`. |
| `branch` | Sync branch used for delivery. |
| `commit-sha` | Merge commit SHA. |
| `pr-url` | Created pull request URL in `mode: pr`. |

## Behavior

1. Fetches `target-branch` from `origin`.
2. Adds or updates a temporary upstream remote and fetches `upstream-ref`.
3. Exits with `changed=false` if the upstream commit is already contained in the target branch.
4. Attempts `git merge --no-commit --no-ff` into a generated sync branch.
5. Invokes Codex only when Git reports unresolved conflict files.
6. Runs `git diff --check`, then the optional `test-command`.
7. Creates the merge commit and either pushes a PR branch or pushes directly to `target-branch`.

## Private upstream repositories

For a private GitHub upstream, store a token that can read the upstream repository and pass it as `upstream-token`:

```yaml
- uses: owner/ai_merge_action@v1
  with:
    openai-api-key: ${{ secrets.OPENAI_API_KEY }}
    github-token: ${{ github.token }}
    upstream-repository: upstream-owner/private-upstream
    upstream-token: ${{ secrets.UPSTREAM_READ_TOKEN }}
```

## Custom OpenAI endpoint

Set `openai-base-url` when Codex should call an OpenAI-compatible endpoint instead of the default OpenAI Responses API:

```yaml
- uses: owner/ai_merge_action@v1
  with:
    openai-api-key: ${{ secrets.OPENAI_API_KEY }}
    openai-base-url: https://proxy.example.com/v1
    github-token: ${{ github.token }}
    upstream-repository: upstream-owner/upstream-repo
```

Internally this action passes `responses-api-endpoint` to `openai/codex-action@v1`. If `openai-base-url` ends with `/responses`, it is used as-is; otherwise the action appends `/responses`.

## Security notes

- Prefer `mode: pr` unless the target repository is safe for unattended direct pushes.
- Enable a GitHub Ruleset or branch protection rule for `main` that blocks force pushes. This action never uses force push, and the repository should reject it if any token or workflow is misconfigured.
- Use scheduled or manual triggers. Avoid running this workflow with secrets on untrusted fork pull requests.
- Keep `OPENAI_API_KEY` in repository or organization secrets.
- The OpenAI key is only passed to `openai/codex-action@v1`, which starts a proxy and runs `codex exec`.
- Codex is asked to resolve merge conflicts only; deterministic shell scripts handle fetching, committing, pushing, and PR creation.

## Local checks

```bash
bash tests/run.sh
shellcheck scripts/*.sh tests/*.sh
actionlint
```
