#!/bin/bash
set -euo pipefail

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required but not found." >&2
  exit 1
fi

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_JSON=""      # set by load_config()
CONFIG_WARNING=""   # set by load_config() on validation failure

validate_config() {
  local config="$1"

  echo "$config" | jq -e '
    (.thresholds | type == "array" and length > 0) and
    (.thresholds | all(
      (.percent | type == "number" and . >= 0 and . <= 100) and
      (.message | type == "string" and length > 0)
    )) and
    (if has("context_size") then .context_size | type == "number" and . > 0 else true end) and
    (if has("debug") then .debug | type == "boolean" else true end)
  ' >/dev/null 2>&1
}

load_config() {
  local config_paths=()

  if [[ -n "${CONTEXT_AWARE_CONFIG:-}" ]]; then
    config_paths+=("$CONTEXT_AWARE_CONFIG")
  fi
  if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
    config_paths+=("$CLAUDE_PROJECT_DIR/.claude/context-aware.json")
  fi
  config_paths+=("$HOME/.claude/context-aware.json")

  local default_config_path="$PLUGIN_ROOT/default-config.json"

  for config_path in "${config_paths[@]}"; do
    if [[ -f "$config_path" ]]; then
      local candidate
      candidate=$(cat "$config_path")
      if validate_config "$candidate"; then
        CONFIG_JSON="$candidate"
        return
      else
        CONFIG_WARNING="[context-aware hook] Invalid config at $config_path — using default config."
        echo "Warning: $CONFIG_WARNING" >&2
        break
      fi
    fi
  done

  CONFIG_JSON=$(cat "$default_config_path")
}

exit_if_already_blocked() {
  local input="$1"
  local stop_hook_active
  stop_hook_active=$(echo "$input" | jq -r '.stop_hook_active // false')
  if [[ "$stop_hook_active" == "true" ]]; then
    exit 0
  fi
}

get_transcript_path() {
  local input="$1"
  local transcript_path
  transcript_path=$(echo "$input" | jq -r '.transcript_path // empty')
  if [[ -z "$transcript_path" || ! -f "$transcript_path" ]]; then
    return 1
  fi
  echo "$transcript_path"
}

get_context_size_for_model() {
  local model="$1"
  local config_size
  config_size=$(echo "$CONFIG_JSON" | jq -r '.context_size // empty')

  # Explicit config override takes precedence
  if [[ -n "$config_size" ]]; then
    echo "$config_size"
    return
  fi

  # Auto-detect from model ID
  case "$model" in
    claude-opus-4-6*)
      echo 1000000
      ;;
    *)
      echo 200000
      ;;
  esac
}

get_context_size() {
  local transcript_path="$1"
  local model
  model=$(jq -rs 'map(select(.message.model)) | first | .message.model // "unknown"' < "$transcript_path")
  get_context_size_for_model "$model"
}

get_token_count() {
  local transcript_path="$1"
  jq -s '
    map(select(.message.usage and .isSidechain != true))
    | last
    | if . then
        (.message.usage.input_tokens // 0)
        + (.message.usage.cache_read_input_tokens // 0)
        + (.message.usage.cache_creation_input_tokens // 0)
      else 0 end
  ' < "$transcript_path"
}

get_reason() {
  local percentage=$1

  local message
  message=$(echo "$CONFIG_JSON" | jq -r --argjson pct "$percentage" '
    .thresholds | sort_by(.percent) | map(select(.percent <= $pct)) | last | .message // empty
  ')

  if [[ -z "$message" ]]; then
    return 1
  fi

  # Interpolate {percent} in message template
  message="${message//\{percent\}/$percentage}"
  echo "[context-aware hook] $message"
}

output_config_warning() {
  if [[ -n "$CONFIG_WARNING" ]]; then
    jq -n --arg sys "$CONFIG_WARNING" '{"decision": "approve", "systemMessage": $sys}'
  fi
}

output_block_decision() {
  local reason="$1"
  local input="$2"

  local debug
  debug=$(echo "$CONFIG_JSON" | jq -r '.debug // false')

  local system_message=""
  if [[ -n "$CONFIG_WARNING" ]]; then
    system_message="$CONFIG_WARNING"
  fi
  if [[ "$debug" == "true" ]]; then
    if [[ -n "$system_message" ]]; then
      system_message="$system_message"$'\n'"$input"
    else
      system_message="$input"
    fi
  fi

  if [[ -n "$system_message" ]]; then
    jq -n --arg reason "$reason" --arg sys "$system_message" \
      '{"decision": "block", "reason": $reason, "systemMessage": $sys}'
  else
    jq -n --arg reason "$reason" \
      '{"decision": "block", "reason": $reason}'
  fi
}

main() {
  local input
  input=$(cat)

  # Prevent infinite loops: if we already blocked once, let Claude stop
  exit_if_already_blocked "$input"

  load_config

  local transcript_path
  if ! transcript_path=$(get_transcript_path "$input"); then
    output_config_warning
    exit 0
  fi

  local context_size
  context_size=$(get_context_size "$transcript_path")

  local token_count
  token_count=$(get_token_count "$transcript_path")

  local percentage=$(( (token_count * 100 + context_size / 2) / context_size ))

  local reason
  if ! reason=$(get_reason "$percentage"); then
    output_config_warning
    exit 0
  fi

  # Threshold met — block; config warning (if any) goes in systemMessage via output_block_decision
  output_block_decision "$reason" "$input"
}

main
