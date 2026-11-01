#!/usr/bin/env bash
# Maintain one active pr-graph run per Claude/Cursor conversation.
# Usage:
#   current.sh init <ticket> <session>
#   current.sh node <session> <NODE> [label]
#   current.sh show <session>
#   current.sh clear <session>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -n "${PR_GRAPH_STATE_ROOT:-}" ]; then
  STATE_ROOT="$PR_GRAPH_STATE_ROOT"
elif [ -f "$SCRIPT_DIR/../.cursor-state-root" ]; then
  IFS= read -r STATE_ROOT < "$SCRIPT_DIR/../.cursor-state-root"
elif [[ "$SCRIPT_DIR" == *"/.cursor/"* ]]; then
  STATE_ROOT="${HOME}/.cursor/pr-graph"
else
  STATE_ROOT="${HOME}/.claude/pr-graph"
fi
if [ -z "$STATE_ROOT" ] || [ "$STATE_ROOT" = "/" ]; then
  echo "ERROR: Refusing unsafe pr-graph state root." >&2
  exit 1
fi

ACTIVE_DIR="${STATE_ROOT}/active"
RUNS_DIR="${STATE_ROOT}/runs"

usage() {
  echo "Usage: current.sh init <ticket> <session> | node <session> <NODE> [label] | show <session> | clear <session>" >&2
  exit 1
}

valid_session() {
  [[ "$1" =~ ^[A-Za-z0-9_-]{1,128}$ ]]
}

require_session() {
  local session="$1"

  if ! valid_session "$session"; then
    echo "ERROR: Missing or malformed conversation identity." >&2
    exit 1
  fi
}

state_file() {
  printf '%s/%s\n' "$ACTIVE_DIR" "$1"
}

generate_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  elif command -v ruby >/dev/null 2>&1; then
    ruby -r securerandom -e 'puts SecureRandom.uuid'
  else
    echo "ERROR: Cannot generate a run UUID (uuidgen or ruby is required)." >&2
    return 1
  fi
}

write_state() {
  local destination="$1"
  shift
  local tmp

  tmp=$(mktemp "${ACTIVE_DIR}/.state.XXXXXX")
  chmod 600 "$tmp"
  printf '%s\n' "$@" > "$tmp"
  mv "$tmp" "$destination"
}

cmd="${1:-}"
[ -n "$cmd" ] || usage
shift

case "$cmd" in
  init)
    ticket="${1:-}"
    session="${2:-}"
    [ -n "$ticket" ] || usage
    if [[ "$ticket" == *$'\n'* ]] || [[ "$ticket" == *$'\r'* ]]; then
      echo "ERROR: Ticket identity must fit on one line." >&2
      exit 1
    fi
    require_session "$session"

    run_id=$(generate_uuid)
    if [[ ! "$run_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
      echo "ERROR: UUID generator returned a malformed run identity." >&2
      exit 1
    fi
    ticket_slug=$(printf '%s' "$ticket" | tr '[:lower:]' '[:upper:]' | tr -cs 'A-Z0-9_' '-')
    ticket_slug="${ticket_slug#-}"
    ticket_slug="${ticket_slug%-}"
    [ -n "$ticket_slug" ] || ticket_slug="RUN"
    events="${RUNS_DIR}/${ticket_slug}-$(date -u +%Y%m%d)-${run_id}.jsonl"

    mkdir -p "$ACTIVE_DIR" "$RUNS_DIR"
    umask 077
    : > "$events"
    write_state "$(state_file "$session")" \
      "events=${events}" \
      "run_id=${run_id}" \
      "ticket=${ticket}" \
      "session=${session}" \
      "node=ORCHESTRATOR" \
      "label=main"
    printf '%s\n' "$events"
    ;;
  node)
    session="${1:-}"
    node="${2:-}"
    label="${3:-}"
    require_session "$session"
    [ -n "$node" ] || usage
    [[ "$node" =~ ^[A-Z][A-Z-]*$ ]] || usage
    if [ -n "$label" ] && [[ ! "$label" =~ ^[A-Za-z0-9._-]{1,128}$ ]]; then
      usage
    fi

    file=$(state_file "$session")
    [ -f "$file" ] || exit 0
    tmp=$(mktemp "${ACTIVE_DIR}/.state.XXXXXX")
    chmod 600 "$tmp"
    grep -v '^node=' "$file" | grep -v '^label=' > "$tmp" || true
    printf 'node=%s\n' "$node" >> "$tmp"
    [ -n "$label" ] && printf 'label=%s\n' "$label" >> "$tmp"
    mv "$tmp" "$file"
    ;;
  show)
    session="${1:-}"
    require_session "$session"
    file=$(state_file "$session")
    [ -f "$file" ] || exit 1
    cat "$file"
    ;;
  clear)
    session="${1:-}"
    require_session "$session"
    rm -f "$(state_file "$session")"
    rm -rf "${STATE_ROOT}/checkpoints/${session}"
    ;;
  *)
    usage
    ;;
esac
