#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"
evidence_root="tasks/evidence/issue-293"
script_dir="$evidence_root/scripts"
asset_dir="src/backend/api/static/console"
asset_backup="$script_dir/rv-2-static-backup"
state_dir="$script_dir/rv-2-state"
uv_cache_dir="$script_dir/uv-cache"
negative_stdout="$script_dir/rv-2-negative-stdout.log"
negative_stderr="$script_dir/rv-2-negative-stderr.log"
negative_body="$script_dir/rv-2-negative-response.json"
server_stdout="$script_dir/rv-2-server-stdout.log"
server_stderr="$script_dir/rv-2-server-stderr.log"
response_body="$script_dir/rv-2-response.json"
evidence_file="$evidence_root/rv-2-api-only-starts.txt"
config_path="$state_dir/config.toml"
port="$(python3 -c 'import socket; probe = socket.socket(); probe.bind(("127.0.0.1", 0)); print(probe.getsockname()[1]); probe.close()')"
negative_port="$(python3 -c 'import socket; probe = socket.socket(); probe.bind(("127.0.0.1", 0)); print(probe.getsockname()[1]); probe.close()')"
server_pid=""
restore_assets=0

cleanup() {
  if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
    if kill -TERM "$server_pid" 2>/dev/null; then
      if wait "$server_pid"; then
        server_exit_status=0
      else
        server_exit_status=$?
      fi
    else
      printf 'failed to stop API-only validation process %s\n' "$server_pid" >&2
    fi
  fi
  if [[ "$restore_assets" == 1 && -d "$asset_backup" ]]; then
    mv "$asset_backup" "$asset_dir"
  fi
  rm -rf "$state_dir"
  rm -f "$negative_stdout" "$negative_stderr" "$negative_body" "$server_stdout" "$server_stderr" "$response_body"
}
trap cleanup EXIT

if [[ -d "$asset_dir" ]]; then
  if [[ -e "$asset_backup" ]]; then
    printf 'stale asset backup exists: %s\n' "$asset_backup" >&2
    exit 1
  fi
  mv "$asset_dir" "$asset_backup"
  restore_assets=1
fi
mkdir -p "$state_dir" "$uv_cache_dir"
cat > "$config_path" <<CONFIG
[agent_runner.console]
port = $port
history_db_path = "$state_dir/console.db"
process_registry_path = "$state_dir/processes.json"
process_log_dir = "$state_dir/process-logs"
CONFIG

printf 'NEGATIVE CONTROL: missing assets with --api-only omitted.\n'
printf 'COMMAND: uv run kc console --no-browser --port %s\n' "$negative_port"
if env UV_CACHE_DIR="$uv_cache_dir" KEDACODE_CONFIG="$config_path" uv run kc console --no-browser --port "$negative_port" >"$negative_stdout" 2>"$negative_stderr"; then
  negative_cli_exit=0
else
  negative_cli_exit=$?
fi
if negative_version_status="$(curl -sS --connect-timeout 1 --max-time 2 -o "$negative_body" -w '%{http_code}' "http://127.0.0.1:$negative_port/api/v1/agent-runner/console/version" 2>/dev/null)"; then
  negative_curl_exit=0
else
  negative_curl_exit=$?
fi
if [[ "$negative_cli_exit" != 1 || "$negative_curl_exit" == 0 || "$negative_version_status" != "000" ]]; then
  printf 'NEGATIVE_CONTROL_FAILED: cli=%s curl=%s http=%s\n' "$negative_cli_exit" "$negative_curl_exit" "$negative_version_status" >&2
  cat "$negative_stdout" "$negative_stderr" >&2
  exit 1
fi

printf 'COMMAND: UV_CACHE_DIR=%s KEDACODE_CONFIG=%s uv run kc console --api-only --no-browser --port %s\n' "$uv_cache_dir" "$config_path" "$port"
( exec env UV_CACHE_DIR="$uv_cache_dir" KEDACODE_CONFIG="$config_path" uv run kc console --api-only --no-browser --port "$port" ) >"$server_stdout" 2>"$server_stderr" &
server_pid=$!
version_status="000"
for attempt in $(seq 1 100); do
  if ! kill -0 "$server_pid" 2>/dev/null; then
    break
  fi
  if version_status="$(curl -sS --connect-timeout 1 --max-time 2 -o "$response_body" -w '%{http_code}' "http://127.0.0.1:$port/api/v1/agent-runner/console/version" 2>/dev/null)"; then
    if [[ "$version_status" == "200" ]]; then
      break
    fi
  fi
  sleep 0.2
done
if [[ "$version_status" != "200" ]]; then
  printf 'API_ASSERTION_FAILED: expected HTTP 200, got %s\n' "$version_status" >&2
  cat "$server_stdout" "$server_stderr" >&2
  exit 1
fi
python3 -c 'import json, sys; payload = json.load(open(sys.argv[1], encoding="utf-8")); assert "version" in payload; print(json.dumps(payload, sort_keys=True))' "$response_body" > "$script_dir/rv-2-version-summary.json"
if grep -Fq 'ERROR' "$server_stdout" "$server_stderr"; then
  printf 'API_ASSERTION_FAILED: startup output contains ERROR.\n' >&2
  cat "$server_stdout" "$server_stderr" >&2
  exit 1
fi
if ! grep -Fq 'Uvicorn running' "$server_stdout" "$server_stderr"; then
  printf 'API_ASSERTION_FAILED: Uvicorn did not report listening.\n' >&2
  cat "$server_stdout" "$server_stderr" >&2
  exit 1
fi
if kill -TERM "$server_pid"; then
  if wait "$server_pid"; then
    server_exit_status=0
  else
    server_exit_status=$?
  fi
else
  printf 'API_ASSERTION_FAILED: could not stop validation server %s.\n' "$server_pid" >&2
  exit 1
fi
server_pid=""

{
  cat <<'EVIDENCE'
Issue #293 — Realistic Validation item 2
Negative control, same missing-assets condition without the opt-in:
EVIDENCE
  printf 'COMMAND: uv run kc console --no-browser --port %s\n' "$negative_port"
  printf 'CLI_EXIT_CODE: %s\n' "$negative_cli_exit"
  printf 'VERSION_CURL_EXIT_CODE: %s\n' "$negative_curl_exit"
  printf 'VERSION_HTTP_STATUS: %s\n' "$negative_version_status"
  printf 'EXPECTED_FAIL: without --api-only, the command exits 1 before listening and the version endpoint cannot return JSON.\n'
  cat <<'EVIDENCE'
Fixed behavior with explicit API-only mode:
EVIDENCE
  printf 'COMMAND: UV_CACHE_DIR=%s KEDACODE_CONFIG=%s uv run kc console --api-only --no-browser --port %s\n' "$uv_cache_dir" "$config_path" "$port"
  printf 'VERSION_HTTP_STATUS: %s\n' "$version_status"
  printf 'VERSION_JSON: '
  cat "$script_dir/rv-2-version-summary.json"
  printf 'SERVER_STOP_STATUS: %s\n' "$server_exit_status"
  printf 'STDOUT:\n'
  cat "$server_stdout"
  printf 'STDERR:\n'
  cat "$server_stderr"
} > "$evidence_file"
rm -f "$script_dir/rv-2-version-summary.json"
cat "$evidence_file"
