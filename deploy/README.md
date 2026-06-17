# Zero-downtime deploy (blue-green via Caddy)

`hermes-webui` updates without dropping the public port. Caddy stays up and
owns the port; two app containers (`hermes-webui-blue` / `hermes-webui-green`)
take turns behind it, sharing the same state volume. The running agent lives in
a separate container, so swapping the WebUI never interrupts in-progress work —
browsers reconnect their SSE stream to the new WebUI automatically.

## Files

| File | Role |
|------|------|
| `Caddyfile` | Public listener; imports the active upstream. Owns the port, never restarts on deploy. |
| `upstream.active` | One-line `reverse_proxy` to the live color. **Rewritten by the deploy script** — don't hand-edit. |
| `../scripts/deploy-bluegreen.sh` | The deploy: start idle color → wait healthy → flip upstream → `caddy reload` → drain → stop old. |

## How a deploy flows

1. Start the idle color from the new image (shared network + state volume; not published).
2. Wait for its Docker `HEALTHCHECK` to report `healthy`.
3. Rewrite `upstream.active` to the new color.
4. `caddy reload` — graceful, drops no in-flight connections.
5. Drain a few seconds, then stop the old color.

If anything fails before step 3, the previous color keeps serving (rollback is free).

## Usage

```bash
# CI / standalone (no agent) — see Jenkinsfile Deploy stage
IMAGE=hermes-webui:ci PUBLIC_PORT=8899 \
  STATE_VOLUME=hermes-webui-ci-state STATE_DIR=/workspace/state \
  scripts/deploy-bluegreen.sh

# Production with the three-container agent stack
IMAGE=ghcr.io/nesquena/hermes-webui:latest PUBLIC_PORT=443 \
  NET=hermes-net \
  STATE_VOLUME=hermes-webui-state STATE_DIR=/home/hermeswebui/.hermes/webui \
  HERMES_HOME_VOLUME=hermes-home HERMES_HOME=/home/hermes/.hermes \
  WORKSPACE_MOUNT="$HOME/workspace:/workspace" \
  scripts/deploy-bluegreen.sh
```

All knobs (network, volumes, drain/health timeouts, password) are environment
variables documented at the top of `scripts/deploy-bluegreen.sh`.

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
