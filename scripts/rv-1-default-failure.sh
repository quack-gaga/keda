#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"
evidence_root="tasks/evidence/issue-293"
script_dir="$evidence_root/scripts"
asset_dir="src/backend/api/static/console"
asset_backup="$script_dir/rv-1-static-backup"
state_dir="$script_dir/rv-1-state"
uv_cache_dir="$script_dir/uv-cache"
stdout_log="$script_dir/rv-1-stdout.log"
stderr_log="$script_dir/rv-1-stderr.log"
negative_stdout="$script_dir/rv-1-negative-stdout.log"
negative_stderr="$script_dir/rv-1-negative-stderr.log"
response_body="$script_dir/rv-1-response.html"
evidence_file="$evidence_root/rv-1-missing-assets-default-fails.txt"
config_path="$state_dir/config.toml"
port="$(python3 -c 'import socket; probe = socket.socket(); probe.bind(("127.0.0.1", 0)); print(probe.getsockname()[1]); probe.close()')"
negative_port="$(python3 -c 'import socket; probe = socket.socket(); probe.bind(("127.0.0.1", 0)); print(probe.getsockname()[1]); probe.close()')"
negative_pid=""
restore_assets=0

cleanup() {
  if [[ -n "$negative_pid" ]]; then
    if kill -0 "$negative_pid" 2>/dev/null; then
      if kill -TERM "$negative_pid" 2>/dev/null; then
        if wait "$negative_pid"; then
          negative_stop_status=0
        else
          negative_stop_status=$?
        fi
      else
        printf 'failed to stop negative-control process %s\n' "$negative_pid" >&2
      fi
    else
      if wait "$negative_pid"; then
        negative_stop_status=0
      else
        negative_stop_status=$?
      fi
    fi
  fi
  if [[ "$restore_assets" == 1 && -d "$asset_backup" ]]; then
    mv "$asset_backup" "$asset_dir"
  fi
  rm -rf "$state_dir"
  rm -rf "$uv_cache_dir"
  rm -f "$stdout_log" "$stderr_log" "$negative_stdout" "$negative_stderr" "$response_body"
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

printf 'NEGATIVE CONTROL: explicitly opt into API-only mode with assets absent.\n'
printf 'COMMAND: kc console --api-only --no-browser --port %s\n' "$negative_port"
( exec env UV_CACHE_DIR="$uv_cache_dir" KEDACODE_CONFIG="$config_path" uv run kc console --api-only --no-browser --port "$negative_port" ) >"$negative_stdout" 2>"$negative_stderr" &
negative_pid=$!
negative_status="000"
for attempt in $(seq 1 100); do
  if ! kill -0 "$negative_pid" 2>/dev/null; then
    break
  fi
  if negative_status="$(curl -sS --connect-timeout 1 --max-time 2 -o "$response_body" -w '%{http_code}' "http://127.0.0.1:$negative_port/" 2>/dev/null)"; then
    if [[ "$negative_status" == "404" ]]; then
      break
    fi
  fi
  sleep 0.2
done
if [[ "$negative_status" != "404" ]] || ! kill -0 "$negative_pid" 2>/dev/null; then
  printf 'NEGATIVE_CONTROL_FAILED: expected API-only listener with root HTTP 404; got %s.\n' "$negative_status" >&2
  cat "$negative_stdout" "$negative_stderr" >&2
  exit 1
fi
if ! grep -Fq 'Uvicorn running' "$negative_stdout" "$negative_stderr"; then
  printf 'NEGATIVE_CONTROL_FAILED: API-only server never reported listening.\n' >&2
  exit 1
fi
if kill -TERM "$negative_pid"; then
  if wait "$negative_pid"; then
    negative_stop_status=0
  else
    negative_stop_status=$?
  fi
  negative_pid=""
else
  printf 'NEGATIVE_CONTROL_FAILED: could not stop process %s.\n' "$negative_pid" >&2
  exit 1
fi

printf 'COMMAND: UV_CACHE_DIR=%s KEDACODE_CONFIG=%s uv run kc console --no-browser --port %s\n' "$uv_cache_dir" "$config_path" "$port"
if env UV_CACHE_DIR="$uv_cache_dir" KEDACODE_CONFIG="$config_path" uv run kc console --no-browser --port "$port" >"$stdout_log" 2>"$stderr_log"; then
  cli_exit_code=0
else
  cli_exit_code=$?
fi

if listener_status="$(curl -sS --connect-timeout 1 --max-time 2 -o "$response_body" -w '%{http_code}' "http://127.0.0.1:$port/" 2>/dev/null)"; then
  listener_probe_exit=0
else
  listener_probe_exit=$?
fi
if [[ "$cli_exit_code" != 1 || "$listener_probe_exit" == 0 || "$listener_status" != "000" ]]; then
  printf 'ASSERTION_FAILED: cli_exit=%s listener_probe_exit=%s listener_status=%s\n' "$cli_exit_code" "$listener_probe_exit" "$listener_status" >&2
  cat "$stdout_log" "$stderr_log" >&2
  exit 1
fi
if grep -Fq 'Uvicorn running' "$stdout_log" "$stderr_log"; then
  printf 'ASSERTION_FAILED: uvicorn started before the command exited.\n' >&2
  exit 1
fi
for required_message in 'just console-sync' 'release wheel' 'kc console --api-only'; do
  if ! grep -Fq "$required_message" "$stderr_log"; then
    printf 'ASSERTION_FAILED: stderr is missing %s\n' "$required_message" >&2
    cat "$stderr_log" >&2
    exit 1
  fi
done

{
  cat <<'EVIDENCE'
Issue #293 — Realistic Validation item 1
Negative control, explicit API-only opt-in with assets absent:
EVIDENCE
  printf 'COMMAND: kc console --api-only --no-browser --port %s\n' "$negative_port"
  printf 'ROOT_HTTP_STATUS: %s\n' "$negative_status"
  printf 'SERVER_STOP_STATUS: %s\n' "$negative_stop_status"
  printf 'EXPECTED_FAIL: item 1 requires the default command to refuse listening; the explicit API-only control keeps the real server listening and / returns 404, so the no-listener oracle turns red.\n'
  cat <<'EVIDENCE'
Historical negative control, pre-fix real entry:
COMMAND: uv run kc console --no-browser --port 59968 (修复前真实运行，静态目录缺失)
OBSERVED: process printed "kc console listening", Uvicorn started, and GET / returned HTTP 404 while the static directory was absent.

Fixed behavior, fresh run:
EVIDENCE
  printf 'COMMAND: UV_CACHE_DIR=%s KEDACODE_CONFIG=%s uv run kc console --no-browser --port %s\n' "$uv_cache_dir" "$config_path" "$port"
  printf 'CLI_EXIT_CODE: %s\n' "$cli_exit_code"
  printf 'LISTENER_PROBE_EXIT_CODE: %s\n' "$listener_probe_exit"
  printf 'LISTENER_HTTP_STATUS: %s\n' "$listener_status"
  printf 'STDOUT:\n'
  cat "$stdout_log"
  printf 'STDERR:\n'
  cat "$stderr_log"
} > "$evidence_file"
cat "$evidence_file"
