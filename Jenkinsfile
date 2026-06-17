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
      steps { sh 'docker build -t "$IMAGE" .' }
    }
    stage('Deploy') {
      steps {
        sh '''
docker rm -f "$NAME" 2>/dev/null || true
docker run -d --name "$NAME" -p "$PORT:8787" -e HERMES_WEBUI_HOST=0.0.0.0 -e HERMES_WEBUI_PORT=8787 -e HERMES_WEBUI_STATE_DIR=/workspace/state "$IMAGE"
for i in $(seq 1 60); do
  H=$(docker inspect --format "{{.State.Health.Status}}" "$NAME" 2>/dev/null) || H=none
  [ "$H" = "healthy" ] && { echo "OK healthy after $i"; exit 0; }
  echo "attempt $i/60: health=$H"; sleep 3
done
echo "FAIL"; docker logs --tail 60 "$NAME"; exit 1
'''
      }
    }
  }
}