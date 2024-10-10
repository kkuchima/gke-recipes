Deploy Stackdriver adapter
```bash
kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/k8s-stackdriver/master/custom-metrics-stackdriver-adapter/deploy/production/adapter_new_resource_model.yaml
```

Deploy sample app and HPA
```bash
kubectl apply -f hello-app.yaml

kubectl apply -f hpa-rps.yaml
```