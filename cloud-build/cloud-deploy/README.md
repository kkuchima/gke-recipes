# Cloud Deploy
```bash
export PROJECT_ID=kkuchima-sandbox
export REGION=asia-northeast1
gcloud deploy apply --file=clouddeploy.yaml --region=${REGION} --project=${PROJECT_ID}


gcloud deploy releases create rel-'$DATE'-'$TIME' \
  --project=${PROJECT_ID} \
  --region=${REGION} \
  --delivery-pipeline=sample-pipeline

#   --images=my-app-image=gcr.io/google-containers/nginx@sha256:f49a843c290594dcf4d193535d1f4ba8af7d56cea2cf79d1e9554f077f1e7aaa
```
