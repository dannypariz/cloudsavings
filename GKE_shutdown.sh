#!/bin/bash

# Set variables for GCP
PROJECT_ID="soleng-dev"
dry_run="false"
GKE_FILE_NAME="gke_list_with_owners.txt"

gcloud container clusters list --project $PROJECT_ID --filter='resourceLabels!=owner' --format='value[separator=":"](name,zone)' > $GKE_FILE_NAME

while IFS= read -r owner_data; do
  GKE_NAME=$(echo $owner_data | cut -d ':' -f1)
  ZONE=$(echo $owner_data | cut -d ':' -f2)
  echo -e "\nGKE Name ==> $GKE_NAME, its ZONE ==> $ZONE ...!!"

  for nodepool in $(gcloud container node-pools list --cluster=$GKE_NAME --zone=$ZONE --format="value(name)"); do
    CURRENT_SIZE=$(gcloud container node-pools describe $nodepool --cluster=$GKE_NAME --zone=$ZONE --format="value(initialNodeCount)")

    if [ $CURRENT_SIZE -eq 0 ]; then
      echo "Node pool $nodepool in cluster $GKE_NAME already has 0 nodes. Skipping..."
    else
      echo -e "Resize the Node Pool - $nodepool in Cluster - $GKE_NAME to 0 [Running in DRY_RUN Mode]"
      if [ "$dry_run" = false ]; then
        echo -e "DRY_RUN is false. Hence perform Resize Node Pool action.."
        gcloud container clusters resize $GKE_NAME --node-pool=$nodepool --num-nodes=0 --zone=$ZONE --quiet --project $PROJECT_ID
      fi
    fi
  done
done < $GKE_FILE_NAME

rm -rf $GKE_FILE_NAME

### sample cmd to run - ./gke_shutdown_no_owner.sh soleng-dev true