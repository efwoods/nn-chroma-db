gcloud compute instances describe chromadb-cpu-us-east1-d \
    --zone=us-east1-d \
    --format='get(networkInterfaces[0].accessConfigs[0].natIP)'
