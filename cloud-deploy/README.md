# Cloud Deploy
```bash
export PROJECT_ID=kkuchima-sandbox
export REGION=asia-northeast1

gcloud deploy apply --file=clouddeploy.yaml --region=${REGION} --project=${PROJECT_ID}

gcloud deploy releases create rel-'$DATE'-'$TIME' \
  --project=${PROJECT_ID} \
  --region=${REGION} \
  --delivery-pipeline=sample-pipeline
```
