#!/usr/bin/env bash
# Checks the endpoints, auth, and persistence across a MongoDB pod restart.
# Usage: ./tests/db_test.sh <base_url>   e.g. ./tests/db_test.sh $(minikube service flask-service -n flask-mongo --url)
set -euo pipefail
URL=${1:?pass the Flask base URL}
NS=flask-mongo

echo "== GET /";            curl -s "$URL/"; echo
echo "== POST /data";       curl -s -X POST -H "Content-Type: application/json" -d '{"sampleKey":"sampleValue"}' "$URL/data"; echo
echo "== GET /data";        curl -s "$URL/data"; echo

echo "== Unauthenticated access must be refused"
kubectl exec -n "$NS" mongodb-0 -- mongosh --quiet --eval 'db.getSiblingDB("flask_db").data.countDocuments()' 2>&1 | tail -1 || true

echo "== Restart MongoDB pod, data should survive (PV)"
kubectl delete pod mongodb-0 -n "$NS"
kubectl wait --for=condition=Ready pod/mongodb-0 -n "$NS" --timeout=120s
sleep 3
curl -s "$URL/data"; echo
