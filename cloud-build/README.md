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