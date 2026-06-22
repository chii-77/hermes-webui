pipeline {
  agent any
  options { disableConcurrentBuilds(); timestamps() }
  triggers { pollSCM('H/5 * * * *') }
  environment { NAME = 'hermes-webui-ci'; IMAGE = 'hermes-webui:ci'; PORT = '8899' }
  stages {
    stage('Test: pytest (gate)') {
      steps {
        sh '''
docker run --rm -v "$PWD":/src -w /src python:3.12-slim sh -c '
  set -e
  apt-get update -qq && apt-get install -y -qq git nodejs >/dev/null
  git config --global user.email ci@local
  git config --global user.name CI
  git config --global --add safe.directory /src
  pip install -q "pyyaml>=6.0" pytest pytest-timeout pytest-asyncio
  pip install -q ruff mcp 2>/dev/null || true
  pytest tests/ -q --timeout=60 --deselect tests/test_bootstrap_foreground.py::TestMainForegroundRouting --deselect tests/test_bootstrap_foreground.py::TestForegroundEnvAndCwd --deselect tests/test_ctl_script.py::test_start_writes_pid_under_hermes_home_runs_foreground_no_browser_and_logs --deselect tests/test_issue570_permission.py::test_load_settings_returns_defaults_when_settings_file_unreadable
'
'''
      }
    }
    stage('Build') {
      // Bake the real version into the image so the WebUI version badge shows a
      // tag / short SHA instead of "unknown". Computed in the workspace (.git is
      // present here; it's excluded from the image build context by .dockerignore).
      steps {
        sh '''
HERMES_VERSION=$(git describe --tags --always 2>/dev/null || echo unknown)
echo "Building with HERMES_VERSION=$HERMES_VERSION"
docker build --build-arg HERMES_VERSION="$HERMES_VERSION" -t "$IMAGE" .
'''
      }
    }
    stage('Deploy') {
      steps {
        // Zero-downtime blue-green: Caddy owns the public port and stays up;
        // the script starts the idle color on the new image, waits for health,
        // flips Caddy's upstream with a graceful reload, then drains the old.
        // On failure before the flip the previous color keeps serving.
        sh '''
IMAGE="$IMAGE" PUBLIC_PORT="$PORT" NET=hermes-net \
  HERMES_HOME_VOLUME=hermes-home HERMES_HOME=/home/hermeswebui/.hermes \
  AGENT_SRC_VOLUME=hermes-agent-src \
  STATE_DIR=/home/hermeswebui/.hermes/webui \
  STATE_UID=1000 STATE_GID=1000 \
  HEALTH_TIMEOUT=600 \
  scripts/deploy-bluegreen.sh
'''
      }
    }
  }
}