#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"
evidence_root="tasks/evidence/issue-293"
script_dir="$evidence_root/scripts"
baseline_doc="$script_dir/rv-4-baseline-agent-runner.md"
baseline_output="$script_dir/rv-4-baseline-grep.txt"
current_output="$script_dir/rv-4-current-grep.txt"
evidence_file="$evidence_root/rv-4-api-only-docs.txt"
baseline_commit="e6b60d94014c3a66cc10b51f7fc9b6a03bc70d96"
cleanup() {
  rm -f "$baseline_doc" "$baseline_output" "$current_output"
}
trap cleanup EXIT

git show "$baseline_commit:docs/guides/agent-runner.md" > "$baseline_doc"
printf 'NEGATIVE CONTROL: pre-fix guide from %s.\n' "$baseline_commit"
if grep -n 'api-only' "$baseline_doc" > "$baseline_output"; then
  printf 'NEGATIVE_CONTROL_FAILED: baseline unexpectedly documents api-only.\n' >&2
  cat "$baseline_output" >&2
  exit 1
else
  baseline_grep_exit=$?
fi
if ! grep -Fq '源码开发模式（wheel 里没有静态产物）时，`kc console` 仍可启动并只' "$baseline_doc"; then
  printf 'NEGATIVE_CONTROL_FAILED: expected stale API-only fallback claim was not present in baseline.\n' >&2
  exit 1
fi

printf 'GREEN COMMAND: grep -n "api-only" docs/guides/agent-runner.md\n'
if grep -n 'api-only' docs/guides/agent-runner.md > "$current_output"; then
  current_grep_exit=0
else
  current_grep_exit=$?
  printf 'DOC_ASSERTION_FAILED: current guide does not mention api-only.\n' >&2
  exit 1
fi
if grep -Fq '源码开发模式（wheel 里没有静态产物）时，`kc console` 仍可启动并只' docs/guides/agent-runner.md; then
  printf 'DOC_ASSERTION_FAILED: obsolete silent API-only statement remains.\n' >&2
  exit 1
fi

{
  cat <<'EVIDENCE'
Issue #293 — Realistic Validation item 4
EVIDENCE
  printf 'NEGATIVE_CONTROL_COMMAND: git show %s:docs/guides/agent-runner.md > %s; grep -n "api-only" %s\n' "$baseline_commit" "$baseline_doc" "$baseline_doc"
  printf 'NEGATIVE_CONTROL_GREP_EXIT_CODE: %s\n' "$baseline_grep_exit"
  printf 'EXPECTED_FAIL: pre-fix guide had no api-only mention and still claimed missing assets silently start API-only.\n'
  printf 'CHECKLIST_COMMAND: grep -n "api-only" docs/guides/agent-runner.md\n'
  printf 'CHECKLIST_GREP_EXIT_CODE: %s\n' "$current_grep_exit"
  cat "$current_output"
  printf 'OBSOLETE_SILENT_FALLBACK_CLAIM: absent\n'
} > "$evidence_file"
cat "$evidence_file"
