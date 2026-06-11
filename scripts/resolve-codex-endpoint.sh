#!/usr/bin/env bash
set -euo pipefail

write_output() {
  local key="$1"
  local value="$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$key" "$value" >>"$GITHUB_OUTPUT"
  fi
}

trim_slashes() {
  local value="$1"
  while [[ "$value" == */ ]]; do
    value="${value%/}"
  done
  printf '%s' "$value"
}

main() {
  local base_url="${INPUT_OPENAI_BASE_URL:-}"
  if [[ -z "$base_url" ]]; then
    write_output responses-api-endpoint ""
    exit 0
  fi

  base_url="$(trim_slashes "$base_url")"

  case "$base_url" in
    */responses)
      write_output responses-api-endpoint "$base_url"
      ;;
    *)
      write_output responses-api-endpoint "$base_url/responses"
      ;;
  esac
}

main "$@"
