#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log "Missing required command: $1"
    exit 1
  fi
}

require_command curl
require_command jq

: "${TR_TORRENT_ID:?Transmission did not pass TR_TORRENT_ID}"
: "${TR_TORRENT_NAME:?Transmission did not pass TR_TORRENT_NAME}"
: "${TR_TORRENT_DIR:?Transmission did not pass TR_TORRENT_DIR}"

RPC_HOST="${TRANSMISSION_RPC_HOST:-127.0.0.1}"
RPC_PORT="${TRANSMISSION_RPC_PORT:-9091}"
RPC_PATH="${TRANSMISSION_RPC_PATH:-/transmission/rpc}"
RPC_URL="${TRANSMISSION_RPC_URL:-http://${RPC_HOST}:${RPC_PORT}${RPC_PATH}}"
RPC_USERNAME="${TRANSMISSION_RPC_USERNAME:-}"
RPC_PASSWORD="${TRANSMISSION_RPC_PASSWORD:-}"
VERIFY_TIMEOUT="${POSTPROCESS_VERIFY_TIMEOUT:-3600}"
POLL_INTERVAL="${POSTPROCESS_POLL_INTERVAL:-10}"

log "Post-processing started for torrent '${TR_TORRENT_NAME}' (ID: ${TR_TORRENT_ID})"

if [[ "$TR_TORRENT_ID" =~ ^[0-9]+$ ]]; then
  TORRENT_IDS_JSON="[$TR_TORRENT_ID]"
else
  TORRENT_IDS_JSON=$(jq -cn --arg id "$TR_TORRENT_ID" '[ $id ]')
fi

SESSION_ID=""

call_rpc() {
  local method=$1
  local args=${2:-{}}
  local payload
  if [[ "$args" == "{}" ]]; then
    payload="{\"method\":\"${method}\"}"
  else
    payload="{\"method\":\"${method}\",\"arguments\":${args}}"
  fi

  while true; do
    local header body http_code
    header=$(mktemp)
    body=$(mktemp)
    local curl_args=(-sS -D "$header" -o "$body" -H "Content-Type: application/json")
    if [[ -n "$SESSION_ID" ]]; then
      curl_args+=(-H "X-Transmission-Session-Id: $SESSION_ID")
    fi
    if [[ -n "$RPC_USERNAME" ]]; then
      curl_args+=(-u "$RPC_USERNAME:$RPC_PASSWORD")
    fi
    if ! curl "${curl_args[@]}" --data "$payload" "$RPC_URL"; then
      log "Failed to contact Transmission RPC at ${RPC_URL}"
      rm -f "$header" "$body"
      exit 1
    fi
    http_code=$(awk 'NR==1 {print $2}' "$header")
    if [[ "$http_code" == "409" ]]; then
      SESSION_ID=$(awk 'BEGIN{IGNORECASE=1} /^X-Transmission-Session-Id/ {print $2}' "$header" | tr -d '\r')
      rm -f "$header" "$body"
      continue
    fi
    if [[ "$http_code" != "200" ]]; then
      log "RPC call '${method}' failed with HTTP status ${http_code}"
      cat "$body" >&2
      rm -f "$header" "$body"
      exit 1
    fi
    cat "$body"
    rm -f "$header" "$body"
    break
  done
}

start_verify() {
  local args
  args=$(jq -cn --argjson ids "$TORRENT_IDS_JSON" '{ids:$ids}')
  log "Requesting torrent verification through RPC"
  call_rpc "torrent-verify" "$args" >/dev/null
}

wait_for_verification() {
  local args elapsed start now
  args=$(jq -cn --argjson ids "$TORRENT_IDS_JSON" '{ids:$ids,"fields":["name","percentDone","recheckState","leftUntilDone","status","errorString"]}')
  start=$(date +%s)
  while true; do
    local info
    info=$(call_rpc "torrent-get" "$args")
    local recheck left status percent error
    recheck=$(jq -r '(.arguments.torrents[0].recheckState // 0)' <<<"$info")
    left=$(jq -r '(.arguments.torrents[0].leftUntilDone // 0)' <<<"$info")
    status=$(jq -r '.arguments.torrents[0].status' <<<"$info")
    percent=$(jq -r '.arguments.torrents[0].percentDone' <<<"$info")
    error=$(jq -r '.arguments.torrents[0].errorString // ""' <<<"$info")
    log "State: recheck=${recheck} status=${status} left=${left} percent=${percent}"
    if [[ -n "$error" ]]; then
      log "Transmission error: $error"
    fi
    if [[ "$recheck" -eq 0 && "$left" -eq 0 ]]; then
      log "Verification complete and torrent fully downloaded"
      break
    fi
    now=$(date +%s)
    elapsed=$((now - start))
    if (( elapsed > VERIFY_TIMEOUT )); then
      log "Timeout waiting for verification/download to finish (>${VERIFY_TIMEOUT}s)"
      exit 1
    fi
    sleep "$POLL_INTERVAL"
  done
}

normalize_segment() {
  local segment=$1
  local expr='(.*)([sS])([0-9]{2})[[:space:]._-]+([eE])([0-9]{2})(.*)'
  while [[ $segment =~ $expr ]]; do
    segment="${BASH_REMATCH[1]}S${BASH_REMATCH[3]}E${BASH_REMATCH[5]}${BASH_REMATCH[6]}"
  done
  printf '%s' "$segment"
}

rename_path_component() {
  local rel="$1"
  local new_name="$2"

  local abs_path="${TR_TORRENT_DIR}/${rel}"
  if [[ ! -e "$abs_path" ]]; then
    log "Skip rename for '${abs_path}' (not found, maybe already renamed)"
    return 1
  fi

  local args
  args=$(jq -cn \
    --argjson ids "$TORRENT_IDS_JSON" \
    --arg path "$abs_path" \
    --arg name "$new_name" \
    '{ids:$ids,path:$path,name:$name}')
  call_rpc "torrent-rename-path" "$args" >/dev/null
  log "Renamed '${rel}' -> '${new_name}'"
}

rename_entry() {
  local rel="$1"
  local IFS='/'
  read -r -a parts <<<"$rel"
  local normalized_parts=()
  local changed=0

  for idx in "${!parts[@]}"; do
    normalized_parts[idx]="$(normalize_segment "${parts[$idx]}")"
    if [[ "${normalized_parts[idx]}" != "${parts[$idx]}" ]]; then
      changed=1
    fi
  done

  (( changed )) || return 1

  local current_rel=""
  for idx in "${!parts[@]}"; do
    local original="${parts[$idx]}"
    local normalized="${normalized_parts[$idx]}"
    local path_rel
    if [[ -n "$current_rel" ]]; then
      path_rel="${current_rel}/${original}"
    else
      path_rel="${original}"
    fi

    if [[ "$original" != "$normalized" ]]; then
      rename_path_component "$path_rel" "$normalized" || true
      original="$normalized"
    fi

    if [[ -n "$current_rel" ]]; then
      current_rel="${current_rel}/${original}"
    else
      current_rel="${original}"
    fi
  done

  return 0
}

rename_all_files() {
  local args
  args=$(jq -cn --argjson ids "$TORRENT_IDS_JSON" '{ids:$ids,"fields":["files"]}')
  local iteration=0
  local max_iterations=50
  while (( iteration < max_iterations )); do
    local data changed=0
    data=$(call_rpc "torrent-get" "$args")
    while IFS= read -r relpath; do
      [[ -z "$relpath" ]] && continue
      if rename_entry "$relpath"; then
        changed=1
      fi
    done < <(jq -r '.arguments.torrents[0].files[]?.name' <<<"$data")
    if (( changed == 0 )); then
      log "No more files to rename"
      return 0
    fi
    ((iteration++))
  done
  log "Reached rename iteration limit without converging"
  return 1
}

is_series_torrent() {
  local args data
  args=$(jq -cn --argjson ids "$TORRENT_IDS_JSON" '{ids:$ids,"fields":["files"]}')
  data=$(call_rpc "torrent-get" "$args")
  while IFS= read -r relpath; do
    [[ -z "$relpath" ]] && continue
    if [[ "$relpath" =~ [sS][0-9]{2}[[:space:]._-]*[eE][0-9]{2} ]]; then
      return 0
    fi
  done < <(jq -r '.arguments.torrents[0].files[]?.name' <<<"$data")
  return 1
}

maybe_move_to_tv_show() {
  if ! is_series_torrent; then
    log "Looks like not a series (no SxxEyy pattern); skip move"
    return 0
  fi

  if [[ "${TR_TORRENT_DIR,,}" == *"/tv show"* ]]; then
    log "Already in tv show folder; skip move"
    return 0
  fi

  if [[ "$TR_TORRENT_DIR" != *"/movie"* ]]; then
    log "Not in a /movie path; skip move"
    return 0
  fi

  local new_dir
  new_dir="${TR_TORRENT_DIR/\/movie/\/tv show}"
  if [[ "$new_dir" == "$TR_TORRENT_DIR" ]]; then
    log "No path change computed; skip move"
    return 0
  fi

  local args
  args=$(jq -cn --argjson ids "$TORRENT_IDS_JSON" --arg loc "$new_dir" '{ids:$ids,"location":$loc,"move":true}')
  log "Detected series; moving data from '${TR_TORRENT_DIR}' to '${new_dir}' via Transmission"
  call_rpc "torrent-set-location" "$args" >/dev/null
  TR_TORRENT_DIR="$new_dir"
}

start_verify
wait_for_verification
maybe_move_to_tv_show
rename_all_files

log "Post-processing completed for torrent '${TR_TORRENT_NAME}'"
