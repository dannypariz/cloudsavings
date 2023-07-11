#!/bin/bash

while getopts p:t:w: flag
do
    case "${flag}" in
        p) PROJECT_ID=${OPTARG};;
        t) SLACK_TOKEN=${OPTARG};;
        w) WORK_DIR=${OPTARG};;
    esac
done

if [[ "$SLACK_TOKEN" == "" || "$PROJECT_ID" == "" ]]; then
  # Prompt the user to select the project ID
  echo "Select the project ID:"
  echo "1. soleng-dev"
  echo "2. soleng-prod"
  read -p "Enter your choice: " CHOICE

  # Set the project ID based on the user's choice
  case $CHOICE in
      1)
          PROJECT_ID="soleng-dev"
          ;;
      2)
          PROJECT_ID="soleng-prod"
          ;;
      *)
          echo "Invalid choice. Exiting."
          exit 1
          ;;
  esac

  # Get the Slack token from user input
  read -p "Enter the Slack token: " SLACK_TOKEN
fi

# select the service account of the project
gcloud auth activate-service-account --key-file="${WORK_DIR}${PROJECT_ID}.json"

# Set variables for GCP
gcloud config set project "$PROJECT_ID" --quiet

# Set variables for Slack
SLACK_URL="https://slack.com/api/chat.postMessage"
SLACK_CHANNEL="#devops-cloud-cost-valid"
SLACK_CHANNEL2="#devops-acceleration"
SLACK_FILE_NAME="slack_data.txt"
VM_FILE_NAME="vm_list_with_owners.txt"

# Get the list of instances without an owner label and add a "delete date" label with the value of today's date plus 14 days
gcloud compute instances list \
--project $PROJECT_ID \
--filter='NOT labels.owner:* AND NOT name:gke*' \
--format='csv(name,labels.delete_date,zone)' \
| tail -n +2 \
| while IFS=',' read -r name delete_date zone; do
    if [[ -z "$delete_date" ]]; then
        today=$(date +%Y%m%d)
        delete_date=$(date -v +14d -j -f "%Y%m%d" "$today" +%Y%m%d)
        gcloud compute instances add-labels "$name" --labels="delete_date=$delete_date" --zone="$zone"
        echo "$name,$delete_date" >> vm_list_without_owner_$PROJECT_ID.csv
    else
        echo "Skipping delete date label on instance $name because it already has a delete date label."
    fi
done

# Get the list of GKE clusters without an owner label and add a "delete date" label with the value of today's date plus 14 days
gcloud container clusters list \
--project $PROJECT_ID \
--format='csv[separator=";"](name,resourceLabels.owner,resourceLabels.delete_date,zone)' \
| tail -n +2 \
| while IFS=';' read -r name owner delete_date zone; do
    if [[ -z "$owner" ]]; then
        if [[ -z "$delete_date" ]]; then
            today=$(date +%Y%m%d)
            delete_date=$(date -v +14d -j -f "%Y%m%d" "$today" +%Y%m%d)
            gcloud container clusters update "$name" --zone="$zone" --update-labels="delete_date=$delete_date"
            echo "$name;$delete_date" >> gke_clusters_without_owner_$PROJECT_ID.csv
        else
            echo "Skipping delete date label on GKE cluster $name because it already has a delete date label."
        fi
    else
        echo "Skipping GKE cluster $name because it has an owner label."
    fi
done


# Get the list of instances with both "delete_date" and "owner" labels and delete the "delete_date" label
gcloud compute instances list \
--project "$PROJECT_ID" \
--format='csv(name,labels.delete_date,labels.owner,zone)' \
| tail -n +2 \
| while IFS=',' read -r name delete_date owner zone; do
    if [[ -n "$delete_date" && -n "$owner" ]]; then
        echo "Deleting the delete_date label for instance $name."
        gcloud compute instances remove-labels "$name" --labels="delete_date" --zone="$zone"
    fi
done

# Get the list of GKE clusters without an owner label and add a "delete date" label with the value of today's date plus 14 days
gcloud container clusters list \
--project $PROJECT_ID \
--format='csv(name,resourceLabels.owner,resourceLabels.delete_date,zone)' \
| tail -n +2 \
| while IFS=',' read -r name owner delete_date zone; do
    if [[ -z "$owner" ]]; then
        if [[ -z "$delete_date" ]]; then
            today=$(date +%Y%m%d)
            delete_date=$(date -v +14d -j -f "%Y%m%d" "$today" +%Y%m%d)
            gcloud container clusters update "$name" --zone="$zone" --update-labels="delete_date=$delete_date"
            echo "$name,$delete_date" >> gke_clusters_without_owner_$PROJECT_ID.csv
        else
            echo "Skipping delete date label on GKE cluster $name because it already has a delete date label."
        fi
    else
        echo "Skipping GKE cluster $name because it has an owner label."
    fi
done


# Make initial request to users.list
response=$(curl -s -X GET \
  -H "Authorization: Bearer $SLACK_TOKEN" \
  -H 'Content-type: application/json' \
  "https://slack.com/api/users.list?include_locale=true")

# Get first 1000 users
echo "user_id,name,real_name,location" > $SLACK_FILE_NAME
echo $response | jq -r '.members[] | "\(.name) == \(.tz)"' | sort >> $SLACK_FILE_NAME

# Get next batch of users (if any)
cursor=$(echo $response | jq -r '.response_metadata.next_cursor')
while [[ "$cursor" != "null" ]]; do
  response=$(curl -s -X GET \
    -H "Authorization: Bearer $SLACK_TOKEN" \
    -H 'Content-type: application/json' \
    "https://slack.com/api/users.list?include_locale=true&cursor=$cursor")
  echo $response | jq -r '.members[] | "\(.name) == \(.tz)"' | sort >> $SLACK_FILE_NAME
  cursor=$(echo $response | jq -r '.response_metadata.next_cursor')
done

gcloud compute instances list --project $PROJECT_ID --filter='labels.owner:* AND labels!=goog-gke-node' --format='value[separator=":"](labels.owner,name,zone)' > $VM_FILE_NAME

while IFS= read -r vm_owner_data; do
  OWNER=$(echo $vm_owner_data | cut -d ':' -f1)
  VM_NAME=$(echo $vm_owner_data | cut -d ':' -f2)
  ZONE=$(echo $vm_owner_data | cut -d ':' -f3)
  loc_of_owner=$(cat $SLACK_FILE_NAME | grep "$OWNER" | head -n 1 | cut -d ' ' -f 3 | tr '[:upper:]' '[:lower:]' | tr '/' '_')
echo -e "\nVM Name ==> $VM_NAME, its OWNER ==> $OWNER, its ZONE ==> $ZONE and Location ==> $loc_of_owner...!!"

if [ -z "$loc_of_owner" ]; then
  echo "Location is empty. Check the OWNER Name. Current OWNER Label is $OWNER...!!!"
else
  # Set timezone
  export TZ="$loc_of_owner"

  # Label the instance with the modified lowercase timezone
  gcloud compute instances add-labels "$VM_NAME" --zone "$ZONE" --project "$PROJECT_ID" --labels="timezone=$TZ"
  echo "Instance $VM_NAME labeled with timezone=$TZ."
fi


done < $VM_FILE_NAME

# Get the list of GKE clusters with an owner label
gcloud container clusters list --project $PROJECT_ID --filter='resourceLabels.owner:*' --format='value[separator=":"](resourceLabels.owner,name,zone)' > gke_clusters_with_owners.txt

while IFS= read -r gke_cluster_owner_data; do
  OWNER=$(echo $gke_cluster_owner_data | cut -d ':' -f1)
  CLUSTER_NAME=$(echo $gke_cluster_owner_data | cut -d ':' -f2)
  ZONE=$(echo $gke_cluster_owner_data | cut -d ':' -f3)
  loc_of_owner=$(cat $SLACK_FILE_NAME | grep "$OWNER" | head -n 1 | cut -d ' ' -f 3 | tr '[:upper:]' '[:lower:]' | tr '/' '_')
  echo -e "\nGKE Cluster Name ==> $CLUSTER_NAME, its OWNER ==> $OWNER, its ZONE ==> $ZONE and Location ==> $loc_of_owner...!!"

  if [ -z "$loc_of_owner" ]; then
    echo "Location is empty. Check the OWNER Name. Current OWNER Label is $OWNER...!!!"
  else
    # Set timezone
    export TZ="$loc_of_owner"

    # Label the GKE cluster with the modified lowercase timezone
    gcloud container clusters update "$CLUSTER_NAME" --zone "$ZONE" --project "$PROJECT_ID" --update-labels="timezone=$TZ,owner=$OWNER"
    echo "GKE Cluster $CLUSTER_NAME labeled with timezone=$TZ and owner=$OWNER."
  fi
done < gke_clusters_with_owners.txt

# Generate a CSV file with the list of instances without an owner label and their respective delete dates
gcloud compute instances list \
--project $PROJECT_ID \
--filter='NOT labels.owner:* AND NOT name:gke*' \
--format='csv(name,labels.delete_date,zone)' \
> vm_list_without_owner_$PROJECT_ID.csv

# Generate a CSV file with the list of GKE clusters without an owner label and their respective delete dates
gcloud container clusters list \
--project $PROJECT_ID \
--format='csv(name,resourceLabels.delete_date,zone)' \
> gke_clusters_without_owner_$PROJECT_ID.csv

# Get the list of instances with an owner label but missing a team/purpose label and save to file
gcloud compute instances list \
--project $PROJECT_ID \
--filter='labels.owner:* AND (NOT labels.team:* OR NOT labels.purpose:*) AND NOT name:gke*' \
--format='csv(name,labels.owner,labels.team,labels.purpose,zone)' \
> vm_list_with_owner_missing_labels_$PROJECT_ID.csv

# Create a new file to change the format for the list from YYYYMMDD to DD/MM/YYYY and delete zones
awk -F, 'BEGIN { OFS="," } NR>1 { split($2, d, ""); $2=d[7] d[8] "/" d[5] d[6] "/" d[1] d[2] d[3] d[4]; NF--; print }' vm_list_without_owner_$PROJECT_ID.csv > modified_vm_list_$PROJECT_ID.csv
awk -F, 'BEGIN { OFS="," } NR>1 && $2 != "" { split($2, d, ""); $2=d[7] d[8] "/" d[5] d[6] "/" d[1] d[2] d[3] d[4]; NF--; print }' gke_clusters_without_owner_$PROJECT_ID.csv > modified_gke_list_$PROJECT_ID.csv
# Get the list of instances without an owner label
NO_OWNER_INSTANCES=$(cat modified_vm_list_$PROJECT_ID.csv | tail -n +1 | tr '\n' '\n' | sed 's/^/ - /')

# Get the list of instances with an owner label but missing a team/purpose label
OWNER_MISSING_LABELS_INSTANCES=$(cat vm_list_with_owner_missing_labels_$PROJECT_ID.csv | tail -n +2 | awk -F ',' '{print $1,"<@"$2">"}' | tr '\n' ',' | sed 's/.$//' | tr ',' '\n')

# Send a Slack message with the list of instances without an owner and delete date to $SLACK_CHANNEL
SLACK_MESSAGE="*${PROJECT_ID}: These GCP instances have no owner and will be deleted on the dates accordingly:*\n$NO_OWNER_INSTANCES"
curl -X POST -H "Authorization: Bearer $SLACK_TOKEN" -H 'Content-type: application/json' --data "{\"channel\":\"$SLACK_CHANNEL\",\"text\":\"$SLACK_MESSAGE\"}" $SLACK_URL

# Add the GKE clusters to the Slack message
NO_OWNER_GKE_CLUSTERS=$(cat modified_gke_list_soleng-dev.csv | tail -n +1 | tr '\n' '\n' | sed 's/^/ - /')
SLACK_MESSAGE="*${PROJECT_ID}: These GKE clusters have no owner and will be deleted on the dates accordingly:*\n$NO_OWNER_GKE_CLUSTERS"
curl -X POST -H "Authorization: Bearer $SLACK_TOKEN" -H 'Content-type: application/json' --data "{\"channel\":\"$SLACK_CHANNEL\",\"text\":\"$SLACK_MESSAGE\"}" $SLACK_URL

# Send a Slack message with the list of instances without an owner and delete date to $SLACK_CHANNEL2 if the list is not empty
if [[ -n "$NO_OWNER_INSTANCES" ]]; then
  SLACK_MESSAGE="*${PROJECT_ID}: These GCP instances have no owner and will be deleted on the dates accordingly:*\n$NO_OWNER_INSTANCES"
  curl -X POST -H "Authorization: Bearer $SLACK_TOKEN" -H 'Content-type: application/json' --data "{\"channel\":\"$SLACK_CHANNEL2\",\"text\":\"$SLACK_MESSAGE\"}" $SLACK_URL
fi

SLACK_MESSAGE="*${PROJECT_ID}: These GCP instances have an owner label but are missing a team/purpose label:*\n$OWNER_MISSING_LABELS_INSTANCES"
curl -X POST -H "Authorization: Bearer $SLACK_TOKEN" -H 'Content-type: application/json' --data "{\"channel\":\"$SLACK_CHANNEL\",\"text\":\"$SLACK_MESSAGE\"}" $SLACK_URL

# Remove the CSV files
rm vm_list_without_owner_$PROJECT_ID.csv vm_list_with_owner_missing_labels_$PROJECT_ID.csv modified_vm_list_$PROJECT_ID.csv gke_clusters_without_owner_$PROJECT_ID.csv
