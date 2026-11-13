# Flask + MongoDB on Kubernetes

A Python Flask API backed by MongoDB with authentication, deployed on Minikube. The setup uses a Deployment, a StatefulSet, Services, a PV and PVC, an HPA, and resource requests and limits.

```
flask-mongodb-app/
├── app.py                  # Flask app (authenticates to MongoDB)
├── requirements.txt
├── Dockerfile
├── render.yaml             # optional: one-click deploy of the app on Render
├── k8s/
│   ├── 00-namespace.yaml
│   ├── 01-mongodb-secret.yaml
│   ├── 02-mongodb-init-configmap.yaml
│   ├── 03-mongodb-pv.yaml
│   ├── 04-mongodb-pvc.yaml
│   ├── 05-mongodb-service.yaml       # headless ClusterIP (internal only)
│   ├── 06-mongodb-statefulset.yaml
│   ├── 07-flask-deployment.yaml      # 2 replicas
│   ├── 08-flask-service.yaml         # NodePort 30080
│   └── 09-flask-hpa.yaml             # 2–5 replicas at 70% CPU
└── tests/
    ├── db_test.sh          # endpoints, auth, persistence
    └── load_test.sh        # high traffic → HPA scale-out
```

## Endpoints

| Method | Path    | Result |
|--------|---------|--------|
| GET    | `/`     | `Welcome to the Flask app! The current time is: <Date and Time>` |
| POST   | `/data` | Inserts the JSON body into `flask_db.data` and returns `{"status": "Data inserted"}` with status 201. A body that is not a JSON object returns 400. |
| GET    | `/data` | Returns all documents without `_id` |

---

## Part 1: Local run (no Kubernetes)

```bash
python3 -m venv venv && source venv/bin/activate
pip install -r requirements.txt
docker run -d -p 27017:27017 --name mongodb mongo:latest
export MONGODB_URI=mongodb://localhost:27017/
flask --app app run      # or: python app.py
```

**Why use a virtual environment (cookie point):** each project gets its own isolated set of packages. Project A can pin `Flask==2.0.2` while project B uses Flask 3 without conflict. The system Python stays clean, and you need no `sudo pip`. The environment can also be rebuilt exactly from `requirements.txt`, which keeps dev, CI and the Docker image consistent.

---

## Part 2: Deploy on Minikube

### Prerequisites
Docker, [Minikube](https://minikube.sigs.k8s.io/docs/start/), and kubectl.

### 1. Start the cluster and enable metrics
```bash
minikube start --driver=docker --cpus=2 --memory=3072
minikube addons enable metrics-server     # the HPA needs this
```

### 2. Build the image and make it available to the cluster

**Option A: push to a container registry (Docker Hub)**
```bash
docker login
docker build -t <dockerhub-user>/flask-mongodb-app:1.0 .
docker push <dockerhub-user>/flask-mongodb-app:1.0
```
Then set `image: <dockerhub-user>/flask-mongodb-app:1.0` in `k8s/07-flask-deployment.yaml`.
For GHCR, use `ghcr.io/<user>/flask-mongodb-app:1.0` after you run `docker login ghcr.io`.

**Option B: local only, no registry**
```bash
docker build -t flask-mongodb-app:1.0 .
minikube image load flask-mongodb-app:1.0
```
The manifest uses `flask-mongodb-app:1.0` with `imagePullPolicy: IfNotPresent`, so this works without changes.

### 3. Apply the manifests
```bash
kubectl apply -f k8s/
kubectl get all,pv,pvc,hpa -n flask-mongo
kubectl wait --for=condition=Ready pod --all -n flask-mongo --timeout=180s
```
The files are numbered, so `kubectl apply -f k8s/` creates them in dependency order.

### 4. Access the app from your machine
```bash
URL=$(minikube service flask-service -n flask-mongo --url)
curl $URL/
curl -X POST -H "Content-Type: application/json" -d '{"sampleKey":"sampleValue"}' $URL/data
curl $URL/data
```
You can also run `kubectl port-forward svc/flask-service 5000:80 -n flask-mongo` and open http://localhost:5000.

### 5. Tear down
```bash
kubectl delete -f k8s/
minikube ssh -- sudo rm -rf /data/mongodb   # optional: wipe the persisted data
```

---

## How each requirement is met

### MongoDB authentication
- The `mongo` image starts `mongod --auth` when `MONGO_INITDB_ROOT_USERNAME` and `MONGO_INITDB_ROOT_PASSWORD` are set. Those values come from the `mongodb-secret` Secret.
- On first boot, `02-mongodb-init-configmap.yaml` runs from `/docker-entrypoint-initdb.d`. It creates a least-privilege user, `flaskuser`, with `readWrite` on `flask_db` only. Flask never uses the root account.
- **Flask code change:** `app.py` builds the connection string from `MONGO_USERNAME`, `MONGO_PASSWORD`, `MONGO_HOST` and `MONGO_AUTH_DB`. The result looks like `mongodb://flaskuser:***@mongodb.flask-mongo.svc.cluster.local:27017/?authSource=flask_db`. The credentials are URL-encoded with `quote_plus`, so special characters in passwords work. If `MONGODB_URI` is set, it overrides the parts. Part 1 and Render use that override.

### Services
- **Flask: `NodePort` (30080).** It load-balances across all Flask pods inside the cluster, and the host reaches it through the node IP.
- **MongoDB: headless `ClusterIP` (`clusterIP: None`).** It has no external IP or node port, so only pods in the cluster can reach the database. The headless type also gives the StatefulSet pod a stable DNS name, `mongodb-0.mongodb`.

### Volumes (PV and PVC)
- `03-mongodb-pv.yaml` is a 1Gi `hostPath` PV at `/data/mongodb` on the Minikube node, with `storageClassName: manual` and reclaim policy `Retain`. Minikube keeps `/data` across restarts.
- `04-mongodb-pvc.yaml` is named `mongodb-data-mongodb-0`. That is exactly the name the StatefulSet's `volumeClaimTemplate` would generate, so the StatefulSet adopts this claim. It binds to the PV through the `app: mongodb` label selector.
- MongoDB's data directory `/data/db` is mounted from that claim. Deleting the pod, or even the StatefulSet, keeps the data.

### Autoscaling
`autoscaling/v2` HPA: `minReplicas: 2`, `maxReplicas: 5`, target average CPU utilization 70%. Utilization is measured against the CPU **request** (200m), so scale-out starts at about 140m per pod.

### Resource requests and limits
Both workloads use `requests: cpu 200m, memory 250M` and `limits: cpu 500m, memory 500M`.

- **Request:** the amount the scheduler *guarantees*. A pod is placed only on a node with that much unreserved capacity. The request also sets the pod's CPU share under contention, and the HPA computes utilization against it.
- **Limit:** the hard ceiling. CPU above the limit is **throttled**. Memory above the limit gets the container **OOM-killed** and restarted.
- **Why set both:** requests prevent overcommitting a node and give the HPA a baseline. Limits stop one noisy pod, such as a runaway query or a memory leak, from starving its neighbors. With request below limit, the pods get the *Burstable* QoS class. They have a guaranteed floor and can burst during spikes.
- For MongoDB, `--wiredTigerCacheSizeGB 0.25` keeps the storage engine cache well inside the 500M limit. Otherwise WiredTiger sizes its cache from the node's RAM, and the container can get OOM-killed.

---

## DNS resolution inside the cluster

1. Every pod's `/etc/resolv.conf` points at the **CoreDNS** Service (`kube-dns` in `kube-system`). It also carries search domains such as `flask-mongo.svc.cluster.local svc.cluster.local cluster.local`.
2. CoreDNS watches the Kubernetes API and creates records for every Service:
   - A normal ClusterIP Service gets `<svc>.<ns>.svc.cluster.local`, which resolves to a stable virtual IP. kube-proxy load-balances that IP to the pods.
   - A **headless** Service (our `mongodb`) resolves directly to the pod IPs. Each StatefulSet pod also gets its own record, such as `mongodb-0.mongodb.flask-mongo.svc.cluster.local`.
3. The pod IPs change when pods restart, but the DNS names stay the same. That is why the app uses a name instead of an IP.

**How Flask connects to MongoDB:** the Deployment sets `MONGO_HOST=mongodb.flask-mongo.svc.cluster.local`. Inside the same namespace, `mongodb` alone also works because of the search domains. pymongo resolves the name through CoreDNS, gets the MongoDB pod IP, and authenticates with the credentials from the Secret. To check from a running pod:
```bash
kubectl run dnsutils -n flask-mongo --rm -it --image=busybox:1.36 --restart=Never -- nslookup mongodb
```

---

## Design choices

| Choice | Why | Alternatives considered |
|---|---|---|
| **StatefulSet** for MongoDB | Stable pod identity (`mongodb-0`), stable DNS, and a per-pod volume that follows the pod. | A Deployment with a PVC. With rolling updates, two pods can try to mount the same RWO volume, and the pod gets no stable identity. |
| **Single MongoDB replica** | Enough for a local assignment and simple to run. | A 3-member replica set with a keyfile for high availability. It is the right production choice but adds complexity and RAM that Minikube can barely spare. |
| **Headless ClusterIP** for Mongo | Internal only, and gives per-pod DNS. | NodePort or LoadBalancer. Both would expose the database outside the cluster, which the assignment explicitly rules out. |
| **NodePort** for Flask | Works on Minikube with no extra add-ons. | LoadBalancer, which needs `minikube tunnel`. Ingress, which needs the ingress add-on and is better for many services or TLS. |
| **Static hostPath PV + `manual` class** | The assignment asks for an explicit PV and PVC, and hostPath maps to a known directory on the node. | Minikube's default `standard` StorageClass with dynamic provisioning. It is simpler, but the PV gets created for you. |
| **Separate app user** (readWrite on `flask_db`) | Least privilege. A leak of the app credentials does not give root on the database. | The app using root. It is simpler but bad practice. |
| **Secret for credentials** | Keeps credentials out of the image and the Deployment spec, and allows rotating them without a rebuild. | A ConfigMap or plain env values in YAML. Both are not meant for credentials. In production: Sealed Secrets, External Secrets, or Vault. |
| **gunicorn** (2 workers × 2 threads) | A production WSGI server that handles concurrent requests. The Flask dev server is single-process and not meant for production. | `flask run` (dev only) and uWSGI (heavier to configure). |
| **`python:3.10-slim`, non-root user** | A small image, and the process cannot run as root inside the container. | Alpine, which has musl and wheel-compatibility issues with some packages, and distroless, which is harder to debug. |
| **Readiness and liveness probes** | Traffic only reaches pods that are ready, and the kubelet restarts a hung pod. | No probes: rollouts and scale-out would send traffic to pods still booting. |
| **`serverSelectionTimeoutMS=5000`** | A request fails in 5s instead of hanging for pymongo's default 30s when Mongo is down. | |

---

## Testing scenarios (cookie point)

### Database interactions: `tests/db_test.sh`
```bash
./tests/db_test.sh $(minikube service flask-service -n flask-mongo --url)
```
The script checks the following:
1. `GET /` returns the welcome message.
2. `POST /data` returns `{"status":"Data inserted"}`, and `GET /data` returns the inserted document.
3. **Authentication is enforced:** an unauthenticated `mongosh` query inside the Mongo pod fails with `requires authentication`.
4. **Persistence:** the script deletes `mongodb-0`, waits for the StatefulSet to recreate it, then runs `GET /data` again. The same documents come back from the PV.

Before the Kubernetes deploy, the same image was also tested against an authenticated `mongo:7.0` container in Docker. It used a password with `@ : /` characters to prove the URL encoding works:
```
GET  /      -> Welcome to the Flask app! The current time is: 2026-11-13 04:24:35
POST /data  -> {"status":"Data inserted"}
POST junk   -> {"error":"Request body must be a JSON object"}   (400)
GET  /data  -> [{"sampleKey":"sampleValue"}]
```

### Autoscaling under high traffic: `tests/load_test.sh`
```bash
./tests/load_test.sh 3          # 3 busybox pods hammering flask-service in a loop
# in another terminal
kubectl get pods -n flask-mongo -w
kubectl top pods -n flask-mongo
```
Expected behavior:
- At idle: `cpu: 1%/70%`, 2 replicas.
- Under load: CPU rises above 70% of the 200m request. The HPA scales 2 → 3 → … → 5, adding replicas about every 15–30s based on the metrics-server scrape interval. The 0.5 CPU limit caps each pod, so load spreads to the new replicas.
- After Ctrl+C, the generators are deleted. After the default 5-minute scale-down stabilization window, the HPA returns to 2.

You can also load test from your machine with `hey -z 2m -c 50 $URL/`.

### Issues to watch for
- **HPA shows `<unknown>/70%`:** metrics-server is not enabled or not ready yet. Run `minikube addons enable metrics-server` and wait about a minute. Also check that the pods have CPU requests; without them, utilization cannot be computed.
- **Init script did not create `flaskuser`:** scripts in `/docker-entrypoint-initdb.d` only run when `/data/db` is empty. If the PV already holds data from an earlier run, wipe it with `minikube ssh -- sudo rm -rf /data/mongodb` and recreate the pod.
- **Flask pods restart at startup before Mongo is up:** the app connects lazily, so `/` stays healthy. `/data` returns an error until Mongo is ready, then recovers without a restart.
- **MongoDB OOMKilled:** this happens when the WiredTiger cache is not capped. It is fixed with `--wiredTigerCacheSizeGB 0.25`.

---

## Optional: deploy the app on Render

Render runs the Docker image directly. It does not use the Kubernetes manifests and offers no managed MongoDB. Use a free **MongoDB Atlas** cluster for the database.

1. Create an Atlas M0 cluster, add a database user, and allow network access from `0.0.0.0/0`. Copy the connection string: `mongodb+srv://user:pass@cluster.xxxxx.mongodb.net/`.
2. Push this folder to a GitHub repo.
3. In Render, choose **New → Blueprint**, select the repo, and paste the Atlas string into `MONGODB_URI`. You can also choose **New → Web Service → Docker** and set `MONGODB_URI` by hand.
4. Render injects `PORT`, and the Dockerfile binds gunicorn to `${PORT:-5000}`.

`dnspython` is already in `requirements.txt`, so the `mongodb+srv://` strings Atlas gives you work as they are.
