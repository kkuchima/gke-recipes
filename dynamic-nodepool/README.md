
# Create a GKE Cluster
```bash
export PROJECT_ID=kkuchima-sandbox
export CLUSTER_NAME=std-01
export REGION=asia-northeast1
export ZONE=asia-northeast1-a

gcloud container clusters create ${CLUSTER_NAME} \
    --region=${REGION} \
    --node-locations=${ZONE} \
    --num-nodes=1
```

# Create Node Pools
```bash
export NODEPOOL1=static-pool
export MACHINE_TYPE1=n2d-standard-2

export NODEPOOL2=dynamic-pool
export MACHINE_TYPE2=n1-standard-1

# Cluster Autoscaler disabled
gcloud container node-pools create ${NODEPOOL1} \
    --region=${REGION} \
    --num-nodes=1 \
    --machine-type=${MACHINE_TYPE1} \
    --cluster=${CLUSTER_NAME} 

# Cluster Autoscaler Enabled
gcloud container node-pools create ${NODEPOOL2} \
    --region=${REGION} \
    --num-nodes=1 \
    --machine-type=${MACHINE_TYPE2} \
    --cluster=${CLUSTER_NAME} \
    --enable-autoscaling \
    --total-min-nodes=1 \
    --total-max-nodes=10

$ kubectl get nodes
NAME                                    STATUS   ROLES    AGE     VERSION
gke-std-01-default-pool-3956a601-c4hd   Ready    <none>   13m     v1.25.8-gke.500
gke-std-01-dynamic-pool-d8a36d95-3m0d   Ready    <none>   9m37s   v1.25.8-gke.500
gke-std-01-static-pool-23ca0c6b-g4hw    Ready    <none>   11m     v1.25.8-gke.50
```

# Deploy balloon pods on dynamic pool
```yaml:balloon-priority.yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: balloon-priority
value: -10
preemptionPolicy: Never
globalDefault: false
description: "Balloon pod priority."
```

```yaml:balloon-deploy.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: balloon-deploy
spec:
  replicas: 3
  selector:
    matchLabels:
      app: balloon
  template:
    metadata:
      labels:
        app: balloon
    spec:
      priorityClassName: balloon-priority
      terminationGracePeriodSeconds: 0
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: cloud.google.com/gke-nodepool
                operator: In
                values:
                - dynamic-pool
      containers:
      - name: busybox
        image: busybox:latest
        command: ["sleep"]
        args: ["infinity"]
        resources:
            requests:
              cpu: 500m
              memory: 1Gi
```

```bash
$ kubectl apply -f balloon-priority.yaml
priorityclass.scheduling.k8s.io/balloon-priority created

$ kubectl apply -f balloon-deploy.yaml
deployment.apps/balloon-deploy created

# balloon pods are running on dynamic-pool
$ kubectl get pods -o wide
NAME                              READY   STATUS    RESTARTS   AGE   IP         NODE                                    NOMINATED NODE   READINESS GATES
balloon-deploy-7588446ff9-mqqll   1/1     Running   0          59s   10.4.4.2   gke-std-01-dynamic-pool-d8a36d95-vsct   <none>           <none>
balloon-deploy-7588446ff9-ts92d   1/1     Running   0          59s   10.4.2.2   gke-std-01-dynamic-pool-d8a36d95-3m0d   <none>           <none>
balloon-deploy-7588446ff9-xhpr5   1/1     Running   0          59s   10.4.3.2   gke-std-01-dynamic-pool-d8a36d95-6sxn   <none>           <none>
```

# Deploy pods on static pool
## The helloweb pods will prefer a node that has a `cloud.google.com/gke-nodepool=static-pool` label
```yaml:hello-app.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: helloweb
  labels:
    app: hello
spec:
  replicas: 3
  selector:
    matchLabels:
      app: hello
  template:
    metadata:
      labels:
        app: hello
    spec:
      affinity:
        nodeAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 20
            preference:
              matchExpressions:
              - key: cloud.google.com/gke-nodepool
                operator: In
                values:
                - static-pool
          - weight: 10
            preference:
              matchExpressions:
              - key: cloud.google.com/gke-nodepool
                operator: In
                values:
                - dynamic-pool
      containers:
      - name: hello-app
        image: us-docker.pkg.dev/google-samples/containers/gke/hello-app:1.0
        ports:
        - containerPort: 8080
        resources:
          requests:
            cpu: 200m
```

```bash
$ kubectl apply -f hello-app.yaml
deployment.apps/helloweb created

# helloweb pods are running on static-pool
$ kubectl get pods -o wide
NAME                              READY   STATUS    RESTARTS   AGE   IP         NODE                                    NOMINATED NODE   READINESS GATES
balloon-deploy-7588446ff9-mqqll   1/1     Running   0          10m   10.4.4.2   gke-std-01-dynamic-pool-d8a36d95-vsct   <none>           <none>
balloon-deploy-7588446ff9-ts92d   1/1     Running   0          10m   10.4.2.2   gke-std-01-dynamic-pool-d8a36d95-3m0d   <none>           <none>
balloon-deploy-7588446ff9-xhpr5   1/1     Running   0          10m   10.4.3.2   gke-std-01-dynamic-pool-d8a36d95-6sxn   <none>           <none>
helloweb-56bf467c54-f7w4s         1/1     Running   0          48s   10.4.1.4   gke-std-01-static-pool-23ca0c6b-g4hw    <none>           <none>
helloweb-56bf467c54-td7ft         1/1     Running   0          4s    10.4.1.5   gke-std-01-static-pool-23ca0c6b-g4hw    <none>           <none>
helloweb-56bf467c54-xv6xc         1/1     Running   0          4s    10.4.1.6   gke-std-01-static-pool-23ca0c6b-g4hw    <none>           <none>

$ kubectl get nodes
NAME                                    STATUS   ROLES    AGE   VERSION
gke-std-01-default-pool-3956a601-c4hd   Ready    <none>   25m   v1.25.8-gke.500
gke-std-01-dynamic-pool-d8a36d95-3m0d   Ready    <none>   21m   v1.25.8-gke.500
gke-std-01-dynamic-pool-d8a36d95-6sxn   Ready    <none>   11m   v1.25.8-gke.500
gke-std-01-dynamic-pool-d8a36d95-vsct   Ready    <none>   11m   v1.25.8-gke.500
gke-std-01-static-pool-23ca0c6b-g4hw    Ready    <none>   23m   v1.25.8-gke.500

# Scale-up helloweb pods to 20 replicas
$ kubectl scale --current-replicas=3 --replicas=20 deployment/helloweb
deployment.apps/helloweb scaled

# helloweb pods are running on static-pool and dynamic-pool
$ kubectl get pods -o wide
NAME                              READY   STATUS    RESTARTS   AGE     IP          NODE                                    NOMINATED NODE   READINESS GATES
balloon-deploy-7588446ff9-bclhz   1/1     Running   0          7m55s   10.4.8.2    gke-std-01-dynamic-pool-d8a36d95-nhfj   <none>           <none>
balloon-deploy-7588446ff9-wwrxs   1/1     Running   0          7m55s   10.4.7.2    gke-std-01-dynamic-pool-d8a36d95-9pnn   <none>           <none>
balloon-deploy-7588446ff9-z9f6m   1/1     Running   0          7m55s   10.4.5.2    gke-std-01-dynamic-pool-d8a36d95-zxxx   <none>           <none>
helloweb-56bf467c54-22k25         1/1     Running   0          7m55s   10.4.6.2    gke-std-01-dynamic-pool-d8a36d95-qsph   <none>           <none>
helloweb-56bf467c54-4hfhf         1/1     Running   0          7m55s   10.4.2.6    gke-std-01-dynamic-pool-d8a36d95-3m0d   <none>           <none>
helloweb-56bf467c54-6sl79         1/1     Running   0          7m56s   10.4.1.11   gke-std-01-static-pool-23ca0c6b-g4hw    <none>           <none>
helloweb-56bf467c54-78xfc         1/1     Running   0          7m55s   10.4.6.3    gke-std-01-dynamic-pool-d8a36d95-qsph   <none>           <none>
helloweb-56bf467c54-7hwqh         1/1     Running   0          7m56s   10.4.1.10   gke-std-01-static-pool-23ca0c6b-g4hw    <none>           <none>
helloweb-56bf467c54-8js7q         1/1     Running   0          7m55s   10.4.2.4    gke-std-01-dynamic-pool-d8a36d95-3m0d   <none>           <none>
helloweb-56bf467c54-bkkhd         1/1     Running   0          7m55s   10.4.4.4    gke-std-01-dynamic-pool-d8a36d95-vsct   <none>           <none>
helloweb-56bf467c54-dkjnk         1/1     Running   0          7m56s   10.4.1.9    gke-std-01-static-pool-23ca0c6b-g4hw    <none>           <none>
helloweb-56bf467c54-f7w4s         1/1     Running   0          10m     10.4.1.4    gke-std-01-static-pool-23ca0c6b-g4hw    <none>           <none>
helloweb-56bf467c54-kgn2d         1/1     Running   0          7m55s   10.4.6.4    gke-std-01-dynamic-pool-d8a36d95-qsph   <none>           <none>
helloweb-56bf467c54-ks89k         1/1     Running   0          7m55s   10.4.3.5    gke-std-01-dynamic-pool-d8a36d95-6sxn   <none>           <none>
helloweb-56bf467c54-nh6gb         1/1     Running   0          7m55s   10.4.4.5    gke-std-01-dynamic-pool-d8a36d95-vsct   <none>           <none>
helloweb-56bf467c54-qstg6         1/1     Running   0          7m56s   10.4.1.7    gke-std-01-static-pool-23ca0c6b-g4hw    <none>           <none>
helloweb-56bf467c54-rzvcr         1/1     Running   0          7m55s   10.4.3.4    gke-std-01-dynamic-pool-d8a36d95-6sxn   <none>           <none>
helloweb-56bf467c54-sp99w         1/1     Running   0          7m56s   10.4.1.8    gke-std-01-static-pool-23ca0c6b-g4hw    <none>           <none>
helloweb-56bf467c54-td7ft         1/1     Running   0          10m     10.4.1.5    gke-std-01-static-pool-23ca0c6b-g4hw    <none>           <none>
helloweb-56bf467c54-txx9x         1/1     Running   0          7m56s   10.4.4.3    gke-std-01-dynamic-pool-d8a36d95-vsct   <none>           <none>
helloweb-56bf467c54-wbnt4         1/1     Running   0          7m55s   10.4.2.5    gke-std-01-dynamic-pool-d8a36d95-3m0d   <none>           <none>
helloweb-56bf467c54-xv6xc         1/1     Running   0          10m     10.4.1.6    gke-std-01-static-pool-23ca0c6b-g4hw    <none>           <none>
helloweb-56bf467c54-zpp4j         1/1     Running   0          7m56s   10.4.3.3    gke-std-01-dynamic-pool-d8a36d95-6sxn   <none>           <none>
```
