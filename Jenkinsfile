pipeline {
  agent any
  options { disableConcurrentBuilds(); timestamps() }
  triggers { pollSCM('H/5 * * * *') }
  environment { NAME = 'hermes-webui-ci'; IMAGE = 'hermes-webui:ci'; PORT = '8899' }
  stages {
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
