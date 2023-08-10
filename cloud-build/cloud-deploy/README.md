# Cloud Deploy
```bash
export PROJECT_ID=kkuchima-sandbox
export REGION=asia-northeast1

gcloud deploy releases create rel-'$DATE'-'$TIME' \
  --project=${PROJECT_ID} \
  --region=${REGION} \
  --delivery-pipeline=sample-pipeline

```
