#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"
evidence_root="tasks/evidence/issue-293"
script_dir="$evidence_root/scripts"
asset_dir="src/backend/api/static/console"
asset_backup="$script_dir/rv-3-static-backup"
state_dir="$script_dir/rv-3-state"
uv_cache_dir="$script_dir/uv-cache"
build_log="$script_dir/rv-3-console-sync.log"
wheel_log="$script_dir/rv-3-wheel-build.log"
wheel_dir="$script_dir/wheel"
negative_stdout="$script_dir/rv-3-negative-stdout.log"
negative_stderr="$script_dir/rv-3-negative-stderr.log"
negative_body="$script_dir/rv-3-negative-response.html"
server_stdout="$script_dir/rv-3-server-stdout.log"
server_stderr="$script_dir/rv-3-server-stderr.log"
response_body="$script_dir/rv-3-response.html"
evidence_file="$evidence_root/rv-3-panel-served.txt"
config_path="$state_dir/config.toml"
negative_port="$(python3 -c 'import socket; probe = socket.socket(); probe.bind(("127.0.0.1", 0)); print(probe.getsockname()[1]); probe.close()')"
panel_port="$(python3 -c 'import socket; probe = socket.socket(); probe.bind(("127.0.0.1", 0)); print(probe.getsockname()[1]); probe.close()')"
server_pid=""
restore_assets=0

cleanup() {
  if [[ -n "$server_pid" ]]; then
    if kill -0 "$server_pid" 2>/dev/null; then
      if kill -TERM "$server_pid" 2>/dev/null; then
        if wait "$server_pid"; then
          server_stop_status=0
        else
          server_stop_status=$?
        fi
      else
        printf 'failed to stop validation process %s\n' "$server_pid" >&2
      fi
    else
      if wait "$server_pid"; then
        server_stop_status=0
      else
        server_stop_status=$?
      fi
    fi
  fi
  if [[ "$restore_assets" == 1 && -d "$asset_backup" ]]; then
    mv "$asset_backup" "$asset_dir"
  fi
  rm -rf "$state_dir"
  rm -rf "$wheel_dir" "$uv_cache_dir"
  rm -f "$build_log" "$wheel_log" "$negative_stdout" "$negative_stderr" "$negative_body" "$server_stdout" "$server_stderr" "$response_body"
}
stop_server() {
  if [[ -n "$server_pid" ]]; then
    if kill -TERM "$server_pid"; then
      if wait "$server_pid"; then
        server_stop_status=0
      else
        server_stop_status=$?
      fi
      server_pid=""
    else
      printf 'failed to stop validation process %s\n' "$server_pid" >&2
      return 1
    fi
  fi
}
trap cleanup EXIT

if [[ -e "$asset_backup" ]]; then
  printf 'stale asset backup exists: %s\n' "$asset_backup" >&2
  exit 1
fi
printf 'BUILD_COMMAND: just console-sync\n'
just console-sync > "$build_log" 2>&1
if [[ ! -f "$asset_dir/index.html" ]]; then
  printf 'BUILD_ASSERTION_FAILED: just console-sync did not produce %s/index.html\n' "$asset_dir" >&2
  tail -n 40 "$build_log" >&2
  exit 1
fi
mkdir -p "$state_dir" "$uv_cache_dir"
cat > "$config_path" <<CONFIG
[agent_runner.console]
port = $panel_port
history_db_path = "$state_dir/console.db"
process_registry_path = "$state_dir/processes.json"
process_log_dir = "$state_dir/process-logs"
CONFIG

printf 'NEGATIVE CONTROL: remove built assets and explicitly permit API-only startup.\n'
mv "$asset_dir" "$asset_backup"
restore_assets=1
printf 'COMMAND: uv run kc console --api-only --no-browser --port %s\n' "$negative_port"
( exec env UV_CACHE_DIR="$uv_cache_dir" KEDACODE_CONFIG="$config_path" uv run kc console --api-only --no-browser --port "$negative_port" ) >"$negative_stdout" 2>"$negative_stderr" &
server_pid=$!
negative_status="000"
for attempt in $(seq 1 100); do
  if ! kill -0 "$server_pid" 2>/dev/null; then
    break
  fi
  if negative_status="$(curl -sS --connect-timeout 1 --max-time 2 -o "$negative_body" -w '%{http_code}' "http://127.0.0.1:$negative_port/" 2>/dev/null)"; then
    if [[ "$negative_status" == "404" ]]; then
      break
    fi
  fi
  sleep 0.2
done
if [[ "$negative_status" != "404" ]]; then
  printf 'NEGATIVE_CONTROL_FAILED: expected API-only root HTTP 404, got %s\n' "$negative_status" >&2
  cat "$negative_stdout" "$negative_stderr" >&2
  exit 1
fi
if ! grep -Fq 'Uvicorn running' "$negative_stdout" "$negative_stderr"; then
  printf 'NEGATIVE_CONTROL_FAILED: API-only server never reported listening.\n' >&2
  exit 1
fi
stop_server
mv "$asset_backup" "$asset_dir"
restore_assets=0

printf 'COMMAND: uv run kc console --no-browser --port %s\n' "$panel_port"
( exec env UV_CACHE_DIR="$uv_cache_dir" KEDACODE_CONFIG="$config_path" uv run kc console --no-browser --port "$panel_port" ) >"$server_stdout" 2>"$server_stderr" &
server_pid=$!
panel_response="000|"
for attempt in $(seq 1 100); do
  if ! kill -0 "$server_pid" 2>/dev/null; then
    break
  fi
  if panel_response="$(curl -sS --connect-timeout 1 --max-time 2 -o "$response_body" -w '%{http_code}|%{content_type}' "http://127.0.0.1:$panel_port/" 2>/dev/null)"; then
    if [[ "$panel_response" == 200\|text/html* ]]; then
      break
    fi
  fi
  sleep 0.2
done
IFS='|' read -r panel_status panel_content_type <<< "$panel_response"
if [[ "$panel_status" != "200" || "$panel_content_type" != text/html* ]]; then
  printf 'PANEL_ASSERTION_FAILED: expected HTTP 200 text/html, got %s\n' "$panel_response" >&2
  cat "$server_stdout" "$server_stderr" >&2
  exit 1
fi
python3 -c 'from pathlib import Path; import sys; panel_html = Path(sys.argv[1]).read_text(encoding="utf-8"); assert "<html" in panel_html.lower(); print("HTML_MARKERS: <!DOCTYPE html>=" + str("<!DOCTYPE html>" in panel_html) + ", <html=" + str("<html" in panel_html.lower()))' "$response_body" > "$script_dir/rv-3-html-summary.txt"
if ! grep -Fq 'Uvicorn running' "$server_stdout" "$server_stderr"; then
  printf 'PANEL_ASSERTION_FAILED: default console did not report listening.\n' >&2
  exit 1
fi
if grep -Fq 'ERROR' "$server_stdout" "$server_stderr"; then
  printf 'PANEL_ASSERTION_FAILED: startup output contains ERROR.\n' >&2
  cat "$server_stdout" "$server_stderr" >&2
  exit 1
fi
stop_server

printf 'WHEEL_BUILD_COMMAND: uv build --wheel --out-dir %s\n' "$wheel_dir"
if env UV_CACHE_DIR="$uv_cache_dir" uv build --wheel --out-dir "$wheel_dir" > "$wheel_log" 2>&1; then
  wheel_build_exit=0
else
  wheel_build_exit=$?
  tail -n 40 "$wheel_log" >&2
  exit "$wheel_build_exit"
fi
wheel_file="$(python3 -c 'from pathlib import Path; import sys; matches = sorted(Path(sys.argv[1]).glob("*.whl")); assert len(matches) == 1; print(matches[0])' "$wheel_dir")"
python3 -c 'import sys, zipfile; archive = zipfile.ZipFile(sys.argv[1]); member = "backend/api/static/console/index.html"; assert member in archive.namelist(); print("WHEEL_ASSET: " + member + " present")' "$wheel_file" > "$script_dir/rv-3-wheel-summary.txt"

{
  cat <<'EVIDENCE'
Issue #293 — Realistic Validation item 3
BUILD_COMMAND: just console-sync
BUILD_RESULT: passed; src/backend/api/static/console/index.html exists.
Negative control, assets moved away:
EVIDENCE
  printf 'COMMAND: uv run kc console --api-only --no-browser --port %s\n' "$negative_port"
  printf 'ROOT_HTTP_STATUS: %s\n' "$negative_status"
  printf 'EXPECTED_FAIL: the item 3 oracle requiring the default panel at / to return 200 fails; with assets absent, the explicitly API-only service returns 404.\n'
  cat <<'EVIDENCE'
Fixed behavior, assets restored:
EVIDENCE
  printf 'COMMAND: UV_CACHE_DIR=%s KEDACODE_CONFIG=%s uv run kc console --no-browser --port %s\n' "$uv_cache_dir" "$config_path" "$panel_port"
  printf 'ROOT_HTTP_STATUS: %s\n' "$panel_status"
  printf 'CONTENT_TYPE: %s\n' "$panel_content_type"
  printf 'HTML_RESPONSE: '
  cat "$script_dir/rv-3-html-summary.txt"
  printf 'WHEEL_BUILD_EXIT_CODE: %s\n' "$wheel_build_exit"
  cat "$script_dir/rv-3-wheel-summary.txt"
  printf 'SERVER_STOP_STATUS: %s\n' "$server_stop_status"
  printf 'STDOUT:\n'
  cat "$server_stdout"
  printf 'STDERR:\n'
  cat "$server_stderr"
} > "$evidence_file"
rm -f "$script_dir/rv-3-html-summary.txt"
rm -f "$script_dir/rv-3-wheel-summary.txt"
cat "$evidence_file"
