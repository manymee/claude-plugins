#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/context-monitor.sh"

# Test counters
PASSED=0
FAILED=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Create temp directory for test config files
TEMP_DIR=$(mktemp -d)
TEMP_TRANSCRIPT="$TEMP_DIR/transcript.jsonl"
trap "rm -rf $TEMP_DIR" EXIT

# Isolate tests from user's personal config (~/.claude/context-aware.json)
export HOME="$TEMP_DIR"

run_test() {
  local name="$1"
  local input="$2"
  local expected_exit="$3"
  local expected_output="${4:-}"
  local env_vars="${5:-}"

  local actual_output
  local actual_exit

  if [[ -n "$env_vars" ]]; then
    actual_output=$(echo "$input" | env -S "$env_vars" bash "$HOOK_SCRIPT" 2>&1) && actual_exit=0 || actual_exit=$?
  else
    actual_output=$(echo "$input" | bash "$HOOK_SCRIPT" 2>&1) && actual_exit=0 || actual_exit=$?
  fi

  local failed=false

  if [[ "$actual_exit" -ne "$expected_exit" ]]; then
    failed=true
  fi

  if [[ -n "$expected_output" && "$actual_output" != *"$expected_output"* ]]; then
    failed=true
  fi

  if [[ "$failed" == "true" ]]; then
    echo -e "${RED}FAIL${NC}: $name"
    echo "  Expected exit: $expected_exit, got: $actual_exit"
    [[ -n "$expected_output" ]] && echo "  Expected output to contain: $expected_output"
    echo "  Actual output: $actual_output"
    ((++FAILED))
  else
    echo -e "${GREEN}PASS${NC}: $name"
    ((++PASSED))
  fi
}

echo "Running tests..."
echo

# Write sample transcript data (low usage - should not block)
cat > "$TEMP_TRANSCRIPT" << 'EOF'
{"type":"assistant","message":{"model":"claude-opus-4-5-20251101","usage":{"input_tokens":100,"cache_creation_input_tokens":500,"cache_read_input_tokens":1000}}}
EOF

# Test: Missing transcript_path exits gracefully
run_test "missing transcript_path exits 0" \
  '{"stop_hook_active": false}' \
  0

# Test: Non-existent transcript file exits gracefully
run_test "non-existent transcript file exits 0" \
  '{"stop_hook_active": false, "transcript_path": "/nonexistent/file.jsonl"}' \
  0

# Test: Already blocked should exit 0 (no action)
run_test "already blocked exits 0" \
  '{"stop_hook_active": true, "transcript_path": "'"$TEMP_TRANSCRIPT"'"}' \
  0

# Test: Low usage should exit 0 (no block needed)
run_test "low usage exits 0" \
  '{"stop_hook_active": false, "transcript_path": "'"$TEMP_TRANSCRIPT"'"}' \
  0

# Create high usage transcript (above 40% threshold)
cat > "$TEMP_TRANSCRIPT" << 'EOF'
{"type":"assistant","message":{"model":"claude-opus-4-5-20251101","usage":{"input_tokens":50000,"cache_creation_input_tokens":30000,"cache_read_input_tokens":20000}}}
EOF

# Test: High usage should output block decision
run_test "high usage (50%) outputs block" \
  '{"stop_hook_active": false, "transcript_path": "'"$TEMP_TRANSCRIPT"'"}' \
  0 \
  '"decision": "block"'

# Create critical usage transcript
cat > "$TEMP_TRANSCRIPT" << 'EOF'
{"type":"assistant","message":{"model":"claude-opus-4-5-20251101","usage":{"input_tokens":100000,"cache_creation_input_tokens":50000,"cache_read_input_tokens":30000}}}
EOF

# Test: Critical usage shows auto-compaction warning
run_test "critical usage (90%) shows auto-compaction warning" \
  '{"stop_hook_active": false, "transcript_path": "'"$TEMP_TRANSCRIPT"'"}' \
  0 \
  "Auto-compaction"

# --- Config resolution tests ---

# Test: Config via CONTEXT_AWARE_CONFIG
# Config with percent: 0 triggers block even on low usage
cat > "$TEMP_TRANSCRIPT" << 'EOF'
{"type":"assistant","message":{"model":"claude-opus-4-5-20251101","usage":{"input_tokens":100,"cache_creation_input_tokens":500,"cache_read_input_tokens":1000}}}
EOF

CONFIG_FILE="$TEMP_DIR/custom-config.json"
cat > "$CONFIG_FILE" << 'EOF'
{
  "thresholds": [
    { "percent": 0, "message": "Custom block at {percent}%." }
  ]
}
EOF

run_test "config via CONTEXT_AWARE_CONFIG triggers block" \
  '{"stop_hook_active": false, "transcript_path": "'"$TEMP_TRANSCRIPT"'"}' \
  0 \
  '"decision": "block"' \
  "CONTEXT_AWARE_CONFIG=$CONFIG_FILE"

# Test: Project-level config via CLAUDE_PROJECT_DIR
PROJECT_DIR="$TEMP_DIR/project"
mkdir -p "$PROJECT_DIR/.claude"
cat > "$PROJECT_DIR/.claude/context-aware.json" << 'EOF'
{
  "thresholds": [
    { "percent": 0, "message": "Project-level block." }
  ]
}
EOF

run_test "project-level config triggers block" \
  '{"stop_hook_active": false, "transcript_path": "'"$TEMP_TRANSCRIPT"'"}' \
  0 \
  "Project-level block" \
  "CLAUDE_PROJECT_DIR=$PROJECT_DIR"

# Test: Invalid config falls back to default config
INVALID_CONFIG="$TEMP_DIR/invalid-config.json"
cat > "$INVALID_CONFIG" << 'EOF'
{
  "thresholds": [
    { "percent": 50 }
  ]
}
EOF

# Test: Invalid config below threshold sends systemMessage without blocking
run_test "invalid config below threshold sends systemMessage" \
  '{"stop_hook_active": false, "transcript_path": "'"$TEMP_TRANSCRIPT"'"}' \
  0 \
  "Invalid config" \
  "CONTEXT_AWARE_CONFIG=$INVALID_CONFIG"

# Test: Invalid config without transcript sends systemMessage without blocking
run_test "invalid config without transcript sends systemMessage" \
  '{"stop_hook_active": false}' \
  0 \
  "Invalid config" \
  "CONTEXT_AWARE_CONFIG=$INVALID_CONFIG"

# Test: Invalid config above threshold shows threshold in reason, warning in systemMessage
cat > "$TEMP_TRANSCRIPT" << 'EOF'
{"type":"assistant","message":{"model":"claude-opus-4-5-20251101","usage":{"input_tokens":50000,"cache_creation_input_tokens":30000,"cache_read_input_tokens":20000}}}
EOF

run_test "invalid config above threshold: threshold in reason, warning in systemMessage" \
  '{"stop_hook_active": false, "transcript_path": "'"$TEMP_TRANSCRIPT"'"}' \
  0 \
  "Handoff recommended" \
  "CONTEXT_AWARE_CONFIG=$INVALID_CONFIG"

# Restore low-usage transcript for remaining tests
cat > "$TEMP_TRANSCRIPT" << 'EOF'
{"type":"assistant","message":{"model":"claude-opus-4-5-20251101","usage":{"input_tokens":100,"cache_creation_input_tokens":500,"cache_read_input_tokens":1000}}}
EOF

# Test: Custom messages with {percent} interpolation
INTERP_CONFIG="$TEMP_DIR/interp-config.json"
cat > "$INTERP_CONFIG" << 'EOF'
{
  "thresholds": [
    { "percent": 0, "message": "Usage is {percent}% of context." }
  ]
}
EOF

run_test "custom message with {percent} interpolation" \
  '{"stop_hook_active": false, "transcript_path": "'"$TEMP_TRANSCRIPT"'"}' \
  0 \
  "Usage is 1% of context" \
  "CONTEXT_AWARE_CONFIG=$INTERP_CONFIG"

# Test: Custom context_size makes low tokens appear as high percentage
SMALL_CTX_CONFIG="$TEMP_DIR/small-ctx-config.json"
cat > "$SMALL_CTX_CONFIG" << 'EOF'
{
  "context_size": 2000,
  "thresholds": [
    { "percent": 50, "message": "Over half at {percent}%." }
  ]
}
EOF

run_test "custom context_size changes percentage calculation" \
  '{"stop_hook_active": false, "transcript_path": "'"$TEMP_TRANSCRIPT"'"}' \
  0 \
  "Over half at 80%" \
  "CONTEXT_AWARE_CONFIG=$SMALL_CTX_CONFIG"

# --- 1M context model tests ---

# Test: claude-opus-4-6 model auto-detects 1M context (100k tokens = 10%, below 40% threshold)
cat > "$TEMP_TRANSCRIPT" << 'EOF'
{"type":"assistant","message":{"model":"claude-opus-4-6","usage":{"input_tokens":50000,"cache_creation_input_tokens":30000,"cache_read_input_tokens":20000}}}
EOF

run_test "1M model: 100k tokens (10%) does not block" \
  '{"stop_hook_active": false, "transcript_path": "'"$TEMP_TRANSCRIPT"'"}' \
  0 \
  ""

# Test: claude-opus-4-6 at 50% of 1M (500k tokens) should block
cat > "$TEMP_TRANSCRIPT" << 'EOF'
{"type":"assistant","message":{"model":"claude-opus-4-6","usage":{"input_tokens":250000,"cache_creation_input_tokens":150000,"cache_read_input_tokens":100000}}}
EOF

run_test "1M model: 500k tokens (50%) blocks with handoff recommended" \
  '{"stop_hook_active": false, "transcript_path": "'"$TEMP_TRANSCRIPT"'"}' \
  0 \
  "Handoff recommended"

# Test: config context_size override takes precedence over model auto-detection
cat > "$TEMP_TRANSCRIPT" << 'EOF'
{"type":"assistant","message":{"model":"claude-opus-4-6","usage":{"input_tokens":50000,"cache_creation_input_tokens":30000,"cache_read_input_tokens":20000}}}
EOF

OVERRIDE_CONFIG="$TEMP_DIR/override-ctx-config.json"
cat > "$OVERRIDE_CONFIG" << 'EOF'
{
  "context_size": 200000,
  "thresholds": [
    { "percent": 40, "message": "Override at {percent}%." }
  ]
}
EOF

run_test "config context_size overrides 1M auto-detection" \
  '{"stop_hook_active": false, "transcript_path": "'"$TEMP_TRANSCRIPT"'"}' \
  0 \
  "Override at 50%" \
  "CONTEXT_AWARE_CONFIG=$OVERRIDE_CONFIG"

# Restore low-usage transcript for remaining tests
cat > "$TEMP_TRANSCRIPT" << 'EOF'
{"type":"assistant","message":{"model":"claude-opus-4-5-20251101","usage":{"input_tokens":100,"cache_creation_input_tokens":500,"cache_read_input_tokens":1000}}}
EOF

# Test: Debug mode via config includes systemMessage
DEBUG_CONFIG="$TEMP_DIR/debug-config.json"
cat > "$DEBUG_CONFIG" << 'EOF'
{
  "debug": true,
  "thresholds": [
    { "percent": 0, "message": "Debug test at {percent}%." }
  ]
}
EOF

run_test "debug mode via config includes systemMessage" \
  '{"stop_hook_active": false, "transcript_path": "'"$TEMP_TRANSCRIPT"'"}' \
  0 \
  "systemMessage" \
  "CONTEXT_AWARE_CONFIG=$DEBUG_CONFIG"

echo
echo "Results: $PASSED passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]] && exit 0 || exit 1
