# Zero-downtime deploy (blue-green via Caddy)

`hermes-webui` updates without dropping the public port. Caddy stays up and
owns the port; two app containers (`hermes-webui-blue` / `hermes-webui-green`)
take turns behind it, sharing the same state volume. The running agent lives in
a separate container, so swapping the WebUI never interrupts in-progress work —
browsers reconnect their SSE stream to the new WebUI automatically.

## Files

| File | Role |
|------|------|
| `Caddyfile` | Public listener; proxies to the **fixed** `hermes-webui-active` Docker alias. Static — never rewritten. Owns the port, doesn't restart on deploy. |
| `agent.compose.yml` | The long-lived `hermes-agent` gateway the WebUI connects to. Brought up once; its own lifecycle. |
| `../scripts/deploy-bluegreen.sh` | The deploy: start idle color → wait healthy → move the `hermes-webui-active` alias to it → `caddy reload` → drain → stop old. |

> Routing uses a **Docker network alias** (`hermes-webui-active`), not a mutable
> config file. The deploy reassigns the alias to the healthy color, so Caddy's
> config never changes and can't drift out of sync — even across Caddy reloads
> or restarts it always resolves to the live container. (Earlier versions wrote
> the color into an `upstream.active` file Caddy imported; that file could get
> left pointing at a stopped color → 502. The alias removes that whole class of bug.)

## Agent (one-time, long-lived)

The WebUI image is minimal and contains no agent — it installs `hermes_cli`
from the agent source at boot and reaches the agent gateway over the network.
So a `hermes-agent` must be running for the WebUI to "open hermes"; without it
the WebUI loads but reports *agent not imported*.

Run the agent **once** on the deploy host and leave it up:

```bash
docker compose -f deploy/agent.compose.yml up -d
```

This creates the shared `hermes-net` network and the `hermes-home` /
`hermes-agent-src` volumes (explicit names, no project prefix) that the deploy
script mounts into each WebUI color. The agent is **not** restarted by WebUI
deploys — push → CI → blue-green swap leaves it untouched. Configure the
agent's credentials/models in the `hermes-home` volume on first run.

## How a deploy flows

1. Start the idle color from the new image (on `hermes-net` with shared home/state volumes; not published).
2. Wait for its Docker `HEALTHCHECK` to report `healthy`.
3. Move the `hermes-webui-active` alias onto the new color (both colors briefly carry it — Caddy round-robins between two healthy backends, no 502).
4. `caddy reload` — graceful, re-resolves the alias; drops no in-flight connections.
5. Drain a few seconds, then stop the old color (the alias now resolves only to the new color).

If anything fails before step 3, the previous color keeps the alias and keeps serving (rollback is free).

## Usage

```bash
# Agent-connected (the real deploy) — what the Jenkinsfile runs.
# Requires `docker compose -f deploy/agent.compose.yml up -d` first.
IMAGE=hermes-webui:ci PUBLIC_PORT=8899 NET=hermes-net \
  HERMES_HOME_VOLUME=hermes-home HERMES_HOME=/home/hermeswebui/.hermes \
  AGENT_SRC_VOLUME=hermes-agent-src \
  STATE_DIR=/home/hermeswebui/.hermes/webui \
  STATE_UID=1000 STATE_GID=1000 \
  scripts/deploy-bluegreen.sh

# Standalone (no agent) — WebUI loads but can't run hermes; for a pure UI smoke test.
IMAGE=hermes-webui:ci PUBLIC_PORT=8899 \
  STATE_VOLUME=hermes-webui-ci-state STATE_DIR=/workspace/state \
  scripts/deploy-bluegreen.sh
```

A rollback helper is available at `scripts/rollback.sh` for switching traffic back to the previous color when the prior container is still present.

When `HERMES_HOME_VOLUME` is set the script runs in **agent-connected** mode:
it mounts the shared home + agent source (ro) and puts WebUI state under the
shared home (both colors share it), and passes `WANTED_UID/GID=STATE_UID/GID`
so the container matches the agent's volume owner. When it's empty the script
runs **standalone**: a dedicated `STATE_VOLUME` chowned to `STATE_UID:STATE_GID`.
All knobs are documented at the top of `scripts/deploy-bluegreen.sh`.

## Notes & limits

- **Shared state must be a persistent named volume** (not the per-container
  ephemeral dir the old deploy used) — that's what lets the new color see
  existing sessions/settings. `save_settings()` writes atomically (temp +
  `os.replace`) so the brief two-process overlap can't tear `settings.json`.
- **TLS / domain:** the bundled `Caddyfile` serves plain HTTP on `:8899` for
  parity with CI. To terminate TLS, replace `:8899` with your hostname and drop
  `auto_https off`; Caddy provisions certs automatically.
- The Caddy container bind-mounts this `deploy/` dir, so it must stay at a
  stable host path across deploys (Jenkins reuses its job workspace, so this
  holds). If you relocate the repo, recreate the Caddy container.
