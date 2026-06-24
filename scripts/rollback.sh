#!/usr/bin/env bash
set -euo pipefail

NET="${NET:-hermes-net}"
ACTIVE_ALIAS="${ACTIVE_ALIAS:-hermes-webui-active}"
CADDY_NAME="${CADDY_NAME:-hermes-caddy}"
WEBUI_PORT="${WEBUI_PORT:-8787}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-180}"
DRAIN_SECONDS="${DRAIN_SECONDS:-8}"

log() { echo "[rollback] $*"; }
die() { echo "[rollback] ERROR: $*" >&2; exit 1; }
container_name() { echo "hermes-webui-$1"; }

container_exists() {
  docker inspect --type container "$1" >/dev/null 2>&1
}

container_is_running() {
  docker inspect --format '{{.State.Running}}' "$1" 2>/dev/null | grep -qx true
}

container_health_status() {
  docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$1" 2>/dev/null || echo missing
}

current_color() {
  for c in blue green; do
    local name; name="$(container_name "$c")"
    if container_exists "$name" && docker inspect -f '{{range .NetworkSettings.Networks}}{{range .Aliases}}{{println .}}{{end}}{{end}}' "$name" 2>/dev/null | grep -qx "$ACTIVE_ALIAS"; then
      echo "$c"
      return 0
    fi
  done

  for c in blue green; do
    local name; name="$(container_name "$c")"
    if container_is_running "$name"; then
      echo "$c"
      return 0
    fi
  done
}

other_color() {
  if [ "$1" = blue ]; then
    echo green
  else
    echo blue
  fi
}

wait_healthy() {
  local name="$1"
  local deadline=$((SECONDS + HEALTH_TIMEOUT))
  while [ "$SECONDS" -lt "$deadline" ]; do
    local status; status="$(container_health_status "$name")"
    if [ "$status" = healthy ]; then
      log "$name is healthy"
      return 0
    fi
    if [ "$status" = missing ]; then
      die "$name disappeared while starting"
    fi
    if ! container_is_running "$name"; then
      docker logs --tail 60 "$name" 2>&1 || true
      die "$name exited before becoming healthy"
    fi
    log "waiting for $name health: $status"
    sleep 3
  done
  docker logs --tail 60 "$name" 2>&1 || true
  die "$name did not become healthy within ${HEALTH_TIMEOUT}s"
}

ensure_active_alias() {
  local name="$1"
  if docker inspect -f '{{range .NetworkSettings.Networks}}{{range .Aliases}}{{println .}}{{end}}{{end}}' "$name" 2>/dev/null | grep -qx "$ACTIVE_ALIAS"; then
    return 0
  fi
  log "attaching alias $ACTIVE_ALIAS to $name"
  docker network disconnect "$NET" "$name" >/dev/null 2>&1 || true
  docker network connect --alias "$ACTIVE_ALIAS" "$NET" "$name" || die "failed to attach $ACTIVE_ALIAS alias to $name"
}

caddy_reload() {
  if container_exists "$CADDY_NAME" && container_is_running "$CADDY_NAME"; then
    docker exec "$CADDY_NAME" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
  else
    log "WARN: Caddy container '$CADDY_NAME' not running; skipping reload"
  fi
}

print_status() {
  echo "Current rollback status"
  echo "-------------------------"
  for c in blue green; do
    local name; name="$(container_name "$c")"
    echo "Container: $name"
    if container_exists "$name"; then
      echo "  Running: $(container_is_running "$name" && echo yes || echo no)"
      echo "  Health: $(container_health_status "$name")"
      echo "  Aliases:"
      docker inspect -f '{{range .NetworkSettings.Networks}}{{range .Aliases}}{{println .}}{{end}}{{end}}' "$name" 2>/dev/null | sed 's/^/    /' || true
    else
      echo "  Status: absent"
    fi
  done
  echo "Caddy container: $CADDY_NAME"
  if container_exists "$CADDY_NAME"; then
    echo "  Running: $(container_is_running "$CADDY_NAME" && echo yes || echo no)"
  else
    echo "  Status: absent"
  fi
}

run_rollback() {
  local active; active="$(current_color || true)"
  if [ -z "$active" ]; then
    die "could not determine current active color"
  fi
  local target; target="$(other_color "$active")"
  local active_name; active_name="$(container_name "$active")"
  local target_name; target_name="$(container_name "$target")"

  if ! container_exists "$target_name"; then
    die "target container $target_name does not exist. Rollback requires the previous color container to still be present."
  fi

  if ! container_is_running "$target_name"; then
    log "starting previous color $target_name"
    docker start "$target_name" >/dev/null
    wait_healthy "$target_name"
  fi

  ensure_active_alias "$target_name"
  caddy_reload || true

  log "draining current color for ${DRAIN_SECONDS}s"
  sleep "$DRAIN_SECONDS"

  if [ "$active_name" != "$target_name" ] && container_is_running "$active_name"; then
    log "stopping old active color $active_name"
    docker stop "$active_name" >/dev/null
  fi

  caddy_reload || true
  log "rollback complete: traffic now routed to $target_name"
}

usage() {
  cat <<EOF
Usage: $0 <command>
Commands:
  status        Show current Blue/Green container and alias state
  rollback      Switch traffic back to the previous color if available
  help          Show this help message

Example:
  ./scripts/rollback.sh status
  ./scripts/rollback.sh rollback
EOF
}

if [ $# -lt 1 ]; then
  usage
  exit 1
fi

case "$1" in
  status)
    print_status
    ;;
  rollback)
    run_rollback
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    die "unknown command: $1"
    ;;
esac
