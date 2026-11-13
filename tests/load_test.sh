#!/usr/bin/env bash
# Generates CPU load on the Flask pods from inside the cluster and watches the HPA.
# Usage: ./tests/load_test.sh [num_load_pods]   (default 3)
set -euo pipefail
NS=flask-mongo
N=${1:-3}

for i in $(seq 1 "$N"); do
  kubectl run "load-generator-$i" -n "$NS" --image=busybox:1.36 --restart=Never -- \
    /bin/sh -c "while true; do wget -q -O- http://flask-service/ >/dev/null; wget -q -O- http://flask-service/data >/dev/null; done"
done

echo "Load running with $N generator pods. Watching HPA (Ctrl+C to stop watching)..."
trap 'echo; echo Cleaning up load generators; for i in $(seq 1 "$N"); do kubectl delete pod "load-generator-$i" -n "$NS" --ignore-not-found; done' EXIT
kubectl get hpa flask-app-hpa -n "$NS" --watch
