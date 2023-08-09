# Create a Repository
```bash
gcloud artifacts repositories create my-repo \
--repository-format=docker \
--location=asia-northeast1 \
--description="my conatiner repo"
```

# Initiate CI 
```bash
gcloud builds submit
```

# Cloud Deploy
```bash
export PROJECT_ID=kkuchima-sandbox
export REGION=asia-northeast1
gcloud deploy apply --file=clouddeploy.yaml --region=${REGION} --project=${PROJECT_ID}

gcloud deploy releases create test-release-001 \
  --project=${PROJECT_ID} \
  --region=${REGION} \
  --delivery-pipeline=my-gke-demo-app-1 \
  --images=my-app-image=gcr.io/google-containers/nginx@sha256:f49a843c290594dcf4d193535d1f4ba8af7d56cea2cf79d1e9554f077f1e7aaa
```