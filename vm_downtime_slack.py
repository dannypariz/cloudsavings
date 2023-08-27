import argparse
import os
import csv
import datetime
import requests
from dateutil.parser import parse
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError
from oauth2client.client import GoogleCredentials

def get_args():
    parser = argparse.ArgumentParser(description="Script to fetch and upload stopped instances data to Slack")
    parser.add_argument("-p", "--project_id", required=True, help="Project ID")
    parser.add_argument("-t", "--slack_token", required=True, help="Slack token")
    parser.add_argument("-w", "--work_dir", required=True, help="Working directory")
    args = parser.parse_args()
    return args

args = get_args()
PROJECT_ID = args.project_id
SLACK_TOKEN = args.slack_token
WORK_DIR = args.work_dir

os.system(f"gcloud auth activate-service-account --key-file='{WORK_DIR}{PROJECT_ID}.json'")
os.system(f"gcloud config set project {PROJECT_ID} --quiet")

# Slack channel name
CHANNEL_NAME = "#devops-cloud-cost-valid"

# Slack API Endpoints
POST_MESSAGE_URL = "https://slack.com/api/chat.postMessage"
UPLOAD_FILE_URL = "https://slack.com/api/files.upload"

# Set the output file name
OUTPUT_FILE = "stopped_instances.csv"

# Authenticate and build the service
credentials = GoogleCredentials.get_application_default()
service = build('compute', 'v1', credentials=credentials)

# Prepare the CSV
with open(OUTPUT_FILE, 'w', newline='') as file:
    writer = csv.writer(file)
    writer.writerow(["Instance Name", "Owner", "Last Start Time", "Status", "Last Stop Time", "Days Since Last Shutdown"])

    # Retrieve all zones in the project
    try:
        request = service.zones().list(project=PROJECT_ID)
        zones = request.execute()
    except HttpError as error:
        print(f"An error has occurred: {error}")
        exit()

    # Iterate over each zone and retrieve instances
    for zone in zones['items']:
        try:
            request = service.instances().list(project=PROJECT_ID, zone=zone['name'])
            response = request.execute()
        except HttpError as error:
            print(f"An error has occurred: {error}")
            continue  # Skip to the next zone if there's an error

        for instance in response.get('items', []):  # Safely get 'items' key value
            if instance['status'] == 'TERMINATED':
                instance_name = instance['name']
                owner = instance.get('labels', {}).get('owner', '')
                last_start_time = instance.get('lastStartTimestamp', '')
                last_stop_time = instance.get('lastStopTimestamp', '')
                status = instance['status']

                # Calculate the number of days since last shutdown
                if last_stop_time:
                    last_stop_time_obj = parse(last_stop_time)
                    now = datetime.datetime.now(last_stop_time_obj.tzinfo)
                    days_since_last_shutdown = (now - last_stop_time_obj).days
                else:
                    days_since_last_shutdown = 'N/A'

                writer.writerow([instance_name, owner, last_start_time, status, last_stop_time, days_since_last_shutdown])

print("Data extraction complete. Output file: " + OUTPUT_FILE)

# New sorted output file name
SORTED_OUTPUT_FILE = "sorted_stopped_instances.csv"

# Read the data from the original output file
with open(OUTPUT_FILE, 'r') as file:
    reader = csv.reader(file)
    data = list(reader)

# Extract the header and data
header = data[0]
data_rows = data[1:]

# Sort the data based on the last column (Days Since Last Shutdown) in descending order
# Handle 'N/A' values by placing them at the end
sorted_data = sorted(data_rows, key=lambda x: float('inf') if x[-1] == 'N/A' else float(x[-1]), reverse=True)

# Write the sorted data to the new output file
with open(SORTED_OUTPUT_FILE, 'w', newline='') as file:
    writer = csv.writer(file)
    writer.writerow(header)
    writer.writerows(sorted_data)

print(f"Data sorted and saved to {SORTED_OUTPUT_FILE}")

# Send a message to the channel
def send_message_to_slack_channel(channel, text):
    headers = {
        "Authorization": f"Bearer {SLACK_TOKEN}",
        "Content-Type": "application/json; charset=utf-8"
    }
    data = {
        "channel": channel,
        "text": text
    }
    response = requests.post(POST_MESSAGE_URL, headers=headers, json=data)
    return response.json()

# Upload a file to the channel
def upload_file_to_slack_channel(channel, file_path):
    headers = {
        "Authorization": f"Bearer {SLACK_TOKEN}"
    }
    data = {
        "channels": channel
    }
    with open(file_path, "rb") as file:
        files = {
            "file": file
        }
        response = requests.post(UPLOAD_FILE_URL, headers=headers, data=data, files=files)
    return response.json()

# Send a message and upload the file to Slack
response_message = send_message_to_slack_channel(CHANNEL_NAME, "Uploading sorted_stopped_instances.csv...")
response_upload = upload_file_to_slack_channel(CHANNEL_NAME, SORTED_OUTPUT_FILE)

if "ok" in response_upload and response_upload["ok"]:
    print("File uploaded successfully to Slack!")
else:
    print("Failed to upload file to Slack!")
