#!/usr/bin/env bash
#
# Zero-downtime (blue-green) deploy for hermes-webui on a single Docker host.
#
# Strategy: Caddy owns the public port and never restarts. Two app containers
# (hermes-webui-blue / hermes-webui-green) take turns serving traffic, sharing
# the same state + HERMES_HOME volumes. Each deploy:
#   1. starts the IDLE color on the new image (not published; reached by Caddy
#      over the user-defined network by container name)
#   2. waits for its Docker HEALTHCHECK to report "healthy"
#   3. rewrites deploy/upstream.active to point at the new color
#   4. `caddy reload` — graceful, drops no in-flight connections
#   5. drains briefly, then stops the old color
# On any failure before the flip, the old color keeps serving (natural rollback).
#
# The running agent lives in a separate container (hermes-agent), so swapping
# the WebUI never interrupts in-progress agent work; browsers reconnect their
# SSE stream to the new WebUI automatically.
#
# Configurable via environment (defaults match the three-container compose):
#   IMAGE                 app image to deploy            (default hermes-webui:ci)
#   PUBLIC_PORT           host port Caddy publishes       (default 8899)
#   NET                   docker network name             (default hermes-net)
#   CADDY_NAME            caddy container name            (default hermes-caddy)
#   CADDY_IMAGE           caddy image                     (default caddy:2-alpine)
#   WEBUI_PORT            in-container app port            (default 8787)
#   STATE_VOLUME          named volume for WebUI state     (default hermes-webui-state)
#   STATE_DIR             mount path for state in container (default /home/hermeswebui/.hermes/webui)
#   HERMES_HOME_VOLUME    named/volume for shared agent home (default ""; empty = standalone, no agent)
#   HERMES_HOME           mount path for HERMES_HOME        (default /home/hermes/.hermes)
#   WORKSPACE_MOUNT       host:container workspace bind     (default ""; empty = skip)
#   WEBUI_PASSWORD        optional HERMES_WEBUI_PASSWORD    (default "")
#   HEALTH_TIMEOUT        seconds to wait for healthy       (default 180)
#   DRAIN_SECONDS         seconds to drain old before stop  (default 8)
#
set -euo pipefail

IMAGE="${IMAGE:-hermes-webui:ci}"
PUBLIC_PORT="${PUBLIC_PORT:-8899}"
NET="${NET:-hermes-net}"
CADDY_NAME="${CADDY_NAME:-hermes-caddy}"
CADDY_IMAGE="${CADDY_IMAGE:-caddy:2-alpine}"
WEBUI_PORT="${WEBUI_PORT:-8787}"
STATE_VOLUME="${STATE_VOLUME:-hermes-webui-state}"
STATE_DIR="${STATE_DIR:-/home/hermeswebui/.hermes/webui}"
HERMES_HOME_VOLUME="${HERMES_HOME_VOLUME:-}"
HERMES_HOME="${HERMES_HOME:-/home/hermes/.hermes}"
WORKSPACE_MOUNT="${WORKSPACE_MOUNT:-}"
WEBUI_PASSWORD="${WEBUI_PASSWORD:-}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-180}"
DRAIN_SECONDS="${DRAIN_SECONDS:-8}"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_DIR="$REPO_DIR/deploy"
UPSTREAM_FILE="$DEPLOY_DIR/upstream.active"

log() { echo "[deploy] $*"; }
die() { echo "[deploy] ERROR: $*" >&2; exit 1; }

container_name() { echo "hermes-webui-$1"; }

# ── Bootstrap shared infrastructure (idempotent) ─────────────────────────────
ensure_infra() {
	docker network inspect "$NET" >/dev/null 2>&1 || {
		log "creating network $NET"; docker network create "$NET" >/dev/null
	}
	docker volume inspect "$STATE_VOLUME" >/dev/null 2>&1 || {
		log "creating volume $STATE_VOLUME"; docker volume create "$STATE_VOLUME" >/dev/null
	}
	if ! docker ps --format '{{.Names}}' | grep -qx "$CADDY_NAME"; then
		log "starting Caddy ($CADDY_NAME) on public port $PUBLIC_PORT"
		docker rm -f "$CADDY_NAME" >/dev/null 2>&1 || true
		docker run -d --name "$CADDY_NAME" --network "$NET" --restart unless-stopped \
			-p "$PUBLIC_PORT:8899" \
			-v "$DEPLOY_DIR/Caddyfile:/etc/caddy/Caddyfile:ro" \
			-v "$DEPLOY_DIR/upstream.active:/etc/caddy/upstream.active:ro" \
			"$CADDY_IMAGE" >/dev/null
	fi
}

caddy_reload() {
	docker exec "$CADDY_NAME" caddy reload \
		--config /etc/caddy/Caddyfile --adapter caddyfile
}

# Active color is the single source of truth: parse it from upstream.active.
current_color() {
	grep -oE 'hermes-webui-(blue|green)' "$UPSTREAM_FILE" 2>/dev/null \
		| head -1 | sed 's/hermes-webui-//'
}

run_webui() {
	local color="$1" name; name="$(container_name "$color")"
	log "starting $name from $IMAGE"
	docker rm -f "$name" >/dev/null 2>&1 || true

	local args=(-d --name "$name" --network "$NET" --restart unless-stopped
		-e HERMES_WEBUI_HOST=0.0.0.0
		-e "HERMES_WEBUI_PORT=$WEBUI_PORT"
		-e "HERMES_WEBUI_STATE_DIR=$STATE_DIR"
		-v "$STATE_VOLUME:$STATE_DIR")
	[ -n "$HERMES_HOME_VOLUME" ] && args+=(-e "HERMES_HOME=$HERMES_HOME" -v "$HERMES_HOME_VOLUME:$HERMES_HOME")
	[ -n "$WORKSPACE_MOUNT" ] && args+=(-v "$WORKSPACE_MOUNT")
	[ -n "$WEBUI_PASSWORD" ] && args+=(-e "HERMES_WEBUI_PASSWORD=$WEBUI_PASSWORD")

	docker run "${args[@]}" "$IMAGE" >/dev/null
}

wait_healthy() {
	local name="$1" deadline=$(( SECONDS + HEALTH_TIMEOUT )) h
	while [ "$SECONDS" -lt "$deadline" ]; do
		h="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$name" 2>/dev/null || echo missing)"
		case "$h" in
			healthy) log "$name healthy"; return 0 ;;
			missing) die "$name disappeared while starting" ;;
		esac
		[ "$(docker inspect --format '{{.State.Running}}' "$name" 2>/dev/null || echo false)" = "true" ] \
			|| { docker logs --tail 60 "$name" 2>&1 || true; die "$name exited before becoming healthy"; }
		log "waiting for $name health: $h"; sleep 3
	done
	docker logs --tail 60 "$name" 2>&1 || true
	die "$name did not become healthy within ${HEALTH_TIMEOUT}s"
}

flip_upstream() {
	local color="$1"
	log "flipping public traffic to $color"
	cat > "$UPSTREAM_FILE" <<EOF
# Active blue-green upstream — REWRITTEN BY scripts/deploy-bluegreen.sh.
reverse_proxy $(container_name "$color"):$WEBUI_PORT {
	flush_interval -1
}
EOF
	caddy_reload
}

main() {
	command -v docker >/dev/null || die "docker not found"
	ensure_infra

	local old new
	old="$(current_color || true)"
	if [ "$old" = "blue" ]; then new="green"; else new="blue"; fi
	log "current active color: ${old:-<none>}; deploying to: $new"

	run_webui "$new"
	wait_healthy "$(container_name "$new")"

	flip_upstream "$new"

	log "draining old color for ${DRAIN_SECONDS}s"
	sleep "$DRAIN_SECONDS"

	if [ -n "$old" ] && [ "$old" != "$new" ]; then
		log "stopping old color: $old"
		docker rm -f "$(container_name "$old")" >/dev/null 2>&1 || true
	fi
	log "deploy complete — serving $new on public port $PUBLIC_PORT"
}

main "$@"
