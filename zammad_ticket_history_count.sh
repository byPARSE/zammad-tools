#!/bin/bash

################################################################################
# Zammad Ticket Count to Elasticsearch Export Script
#
# Description:
#   This script reads ticket counts from Zammad grouped by group and state,
#   and exports them to Elasticsearch with timestamps for historical tracking
#   and analysis.
#   USE AT YOUR OWN RISK! NOT COVERED BY ZAMMAD SUPPORT!
# 
# Author: Tobias Siudak
# Version: 1.0.0
# Date: 2025-10-14
# License: MIT License
#
# Repository: https://github.com/byPARSE/zammad-tools
# Issues: https://github.com/byPARSE/zammad-tools/issues
#
# Requirements:
#   - bash >= 4.0
#   - curl
#   - jq (for JSON parsing)
#   - Zammad instance with API access
#   - Elasticsearch instance
#
# Install requirements:
#
#   Ubuntu:
#       sudo apt install curl jq
#
#   CentOS/RHEL:
#       sudo yum install curl jq
#
# Usage:
#   ./zammad_ticket_history_count.sh
#
# Configuration:
#   Edit the configuration variables section below before first use!
#
################################################################################
#
# MIT License
#
# Copyright (c) 2025 Tobias Siudak
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
################################################################################


# ============================================================================
# Configuration Variables
# ============================================================================

# Flag to delete all documents from today before writing new ones
only_one_dataset_per_day=false

# Elasticsearch configuration
elasticsearch_index_name="zammad_history_ticket_count"
elasticsearch_host="localhost"
elasticsearch_port=9200
elasticsearch_protocol="https"   # Options: "http" or "https"
elasticsearch_username=""
elasticsearch_password=""
elasticsearch_ignore_ssl_issues=false

# Zammad configuration
zammad_host="<zammad hostname>"
zammad_protocol="https"   # Options: "http" or "https"
zammad_token="<your token>"
zammad_ignore_ssl_issues=false

# Logging configuration
log_level="error"  # Options: "error" or "debug"
log_path="/var/log/zammad_ticket_history.log"
log_days=14

# ============================================================================
# Script Initialization
# ============================================================================

# Get current timestamp
current_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
current_date=$(date -u +"%Y-%m-%d")

# ============================================================================
# Functions
# ============================================================================

# Function to write log messages
log_message() {
    local level=$1
    local message=$2
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")

    if [[ "$log_level" == "debug" ]] || [[ "$level" == "ERROR" ]] || [[ "$level" == "INFO" && "$log_level" == "error" ]]; then
        echo "[$timestamp] [$level] $message" >> "$log_path"
    fi
}

# Function to clean up old log files
cleanup_old_logs() {
    if [[ -f "$log_path" ]]; then
        find "$(dirname "$log_path")" -name "$(basename "$log_path")*" -type f -mtime +$log_days -delete 2>/dev/null
    fi
}

# Function to build curl SSL options
get_ssl_options() {
    local ignore_ssl=$1
    if [[ "$ignore_ssl" == "true" ]]; then
        echo "-k"
    else
        echo ""
    fi
}

# Function to build Elasticsearch URL
get_elasticsearch_base_url() {
    echo "${elasticsearch_protocol}://${elasticsearch_host}:${elasticsearch_port}"
}

# Function to build Zammad URL
get_zammad_base_url() {
    echo "${zammad_protocol}://${zammad_host}"
}

# Function to build authentication for Elasticsearch
get_elasticsearch_auth() {
    if [[ -n "$elasticsearch_username" ]] && [[ -n "$elasticsearch_password" ]]; then
        echo "-u ${elasticsearch_username}:${elasticsearch_password}"
    else
        echo ""
    fi
}

# Function to check if Elasticsearch index exists
check_elasticsearch_index() {
    local es_base_url=$(get_elasticsearch_base_url)
    local es_auth=$(get_elasticsearch_auth)
    local ssl_opts=$(get_ssl_options "$elasticsearch_ignore_ssl_issues")

    log_message "DEBUG" "Checking if Elasticsearch index '${elasticsearch_index_name}' exists"

    local response=$(curl -s -o /dev/null -w "%{http_code}" $ssl_opts $es_auth \
        "${es_base_url}/${elasticsearch_index_name}")

    if [[ "$response" == "200" ]]; then
        log_message "DEBUG" "Index '${elasticsearch_index_name}' exists"
        return 0
    else
        log_message "DEBUG" "Index '${elasticsearch_index_name}' does not exist"
        return 1
    fi
}

# Function to create Elasticsearch index
create_elasticsearch_index() {
    local es_base_url=$(get_elasticsearch_base_url)
    local es_auth=$(get_elasticsearch_auth)
    local ssl_opts=$(get_ssl_options "$elasticsearch_ignore_ssl_issues")

    log_message "DEBUG" "Creating Elasticsearch index '${elasticsearch_index_name}'"

    local index_mapping='{
  "mappings": {
    "properties": {
      "group": {
        "properties": {
          "name": { "type": "keyword" },
          "id": { "type": "integer" }
        }
      },
      "state": {
        "properties": {
          "name": { "type": "keyword" },
          "id": { "type": "integer" }
        }
      },
      "ticket_count": { "type": "integer" },
      "date": { "type": "date" },
      "created_at": { "type": "date" }
    }
  }
}'

    local response=$(curl -s -w "\n%{http_code}" $ssl_opts $es_auth \
        -X PUT "${es_base_url}/${elasticsearch_index_name}" \
        -H "Content-Type: application/json" \
        -d "$index_mapping")

    local http_code=$(echo "$response" | tail -n1)

    if [[ "$http_code" == "200" ]] || [[ "$http_code" == "201" ]]; then
        log_message "DEBUG" "Index '${elasticsearch_index_name}' created successfully"
        return 0
    else
        log_message "ERROR" "Failed to create index '${elasticsearch_index_name}'. HTTP Code: $http_code"
        return 1
    fi
}

# Function to delete documents from today
delete_todays_documents() {
    local es_base_url=$(get_elasticsearch_base_url)
    local es_auth=$(get_elasticsearch_auth)
    local ssl_opts=$(get_ssl_options "$elasticsearch_ignore_ssl_issues")

    log_message "DEBUG" "Deleting documents from today (${current_date})"

    local delete_query='{
  "query": {
    "range": {
      "date": {
        "gte": "'"${current_date}"'T00:00:00.000Z",
        "lte": "'"${current_date}"'T23:59:59.999Z"
      }
    }
  }
}'

    local response=$(curl -s -w "\n%{http_code}" $ssl_opts $es_auth \
        -X POST "${es_base_url}/${elasticsearch_index_name}/_delete_by_query" \
        -H "Content-Type: application/json" \
        -d "$delete_query")

    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | sed '$d')

    if [[ "$http_code" == "200" ]]; then
        local deleted_count=$(echo "$body" | grep -o '"deleted":[0-9]*' | cut -d':' -f2)
        log_message "DEBUG" "Deleted $deleted_count documents from today"
        return 0
    else
        log_message "ERROR" "Failed to delete today's documents. HTTP Code: $http_code"
        return 1
    fi
}

# Function to fetch all groups from Zammad
fetch_zammad_groups() {
    local zammad_base_url=$(get_zammad_base_url)
    local ssl_opts=$(get_ssl_options "$zammad_ignore_ssl_issues")

    log_message "DEBUG" "Fetching all groups from Zammad"

    local response=$(curl -s $ssl_opts \
        -H "Authorization: Token token=${zammad_token}" \
        "${zammad_base_url}/api/v1/groups")

    if [[ $? -eq 0 ]]; then
        log_message "DEBUG" "Successfully fetched groups from Zammad"
        echo "$response"
        return 0
    else
        log_message "ERROR" "Failed to fetch groups from Zammad"
        return 1
    fi
}

# Function to fetch all ticket states from Zammad
fetch_zammad_states() {
    local zammad_base_url=$(get_zammad_base_url)
    local ssl_opts=$(get_ssl_options "$zammad_ignore_ssl_issues")

    log_message "DEBUG" "Fetching all ticket states from Zammad"

    local response=$(curl -s $ssl_opts \
        -H "Authorization: Token token=${zammad_token}" \
        "${zammad_base_url}/api/v1/ticket_states")

    if [[ $? -eq 0 ]]; then
        log_message "DEBUG" "Successfully fetched ticket states from Zammad"
        echo "$response"
        return 0
    else
        log_message "ERROR" "Failed to fetch ticket states from Zammad"
        return 1
    fi
}

# Function to fetch ticket count for a specific group and state
fetch_ticket_count() {
    local group_id=$1
    local state_name=$2
    local zammad_base_url=$(get_zammad_base_url)
    local ssl_opts=$(get_ssl_options "$zammad_ignore_ssl_issues")

    # URL encode the state name
    local encoded_state_name=$(echo "$state_name" | sed 's/ /%20/g')

    log_message "DEBUG" "Fetching ticket count for group_id=${group_id}, state=${state_name}"

    local response=$(curl -s $ssl_opts \
        -H "Authorization: Token token=${zammad_token}" \
        "${zammad_base_url}/api/v1/tickets/search?query=group.id:${group_id}%20AND%20state.name:${encoded_state_name}&only_total_count=true")

    if [[ $? -eq 0 ]]; then
        local count=$(echo "$response" | grep -o '"count":[0-9]*' | cut -d':' -f2)
        if [[ -n "$count" ]]; then
            log_message "DEBUG" "Ticket count: $count"
            echo "$count"
            return 0
        else
            # No count found - this is normal if there are no tickets for this combination
            log_message "DEBUG" "No tickets found for group_id=${group_id}, state=${state_name} (count=0)"
            echo "0"
            return 0
        fi
    else
        log_message "ERROR" "Failed to fetch ticket count (curl error)"
        echo "0"
        return 1
    fi
}

# Function to index document into Elasticsearch
index_document() {
    local group_id=$1
    local group_name=$2
    local state_id=$3
    local state_name=$4
    local ticket_count=$5

    local es_base_url=$(get_elasticsearch_base_url)
    local es_auth=$(get_elasticsearch_auth)
    local ssl_opts=$(get_ssl_options "$elasticsearch_ignore_ssl_issues")

    log_message "DEBUG" "Indexing document: group=${group_name}, state=${state_name}, count=${ticket_count}"

    local document='{
  "group": {
    "name": "'"${group_name}"'",
    "id": '"${group_id}"'
  },
  "state": {
    "name": "'"${state_name}"'",
    "id": '"${state_id}"'
  },
  "ticket_count": '"${ticket_count}"',
  "date": "'"${current_timestamp}"'",
  "created_at": "'"${current_timestamp}"'"
}'

    local response=$(curl -s -w "\n%{http_code}" $ssl_opts $es_auth \
        -X POST "${es_base_url}/${elasticsearch_index_name}/_doc" \
        -H "Content-Type: application/json" \
        -d "$document")

    local http_code=$(echo "$response" | tail -n1)

    if [[ "$http_code" == "200" ]] || [[ "$http_code" == "201" ]]; then
        log_message "DEBUG" "Document indexed successfully"
        return 0
    else
        log_message "ERROR" "Failed to index document. HTTP Code: $http_code"
        return 1
    fi
}

# ============================================================================
# Main Script Execution
# ============================================================================

# Clean up old logs
cleanup_old_logs

# Log script start
log_message "INFO" "=== Script started ==="

# Check if Elasticsearch index exists, create if not
if ! check_elasticsearch_index; then
    if ! create_elasticsearch_index; then
        log_message "ERROR" "Failed to create Elasticsearch index. Exiting."
        log_message "INFO" "=== Script ended with errors ==="
        exit 1
    fi
fi

# Delete today's documents if flag is set
if [[ "$only_one_dataset_per_day" == "true" ]]; then
    log_message "DEBUG" "Flag 'only_one_dataset_per_day' is set to true"
    if ! delete_todays_documents; then
        log_message "ERROR" "Failed to delete today's documents. Continuing anyway."
    fi
fi

# Fetch all groups from Zammad
groups_json=$(fetch_zammad_groups)
if [[ $? -ne 0 ]]; then
    log_message "ERROR" "Failed to fetch groups. Exiting."
    log_message "INFO" "=== Script ended with errors ==="
    exit 1
fi

# Fetch all states from Zammad
states_json=$(fetch_zammad_states)
if [[ $? -ne 0 ]]; then
    log_message "ERROR" "Failed to fetch states. Exiting."
    log_message "INFO" "=== Script ended with errors ==="
    exit 1
fi

# Parse groups (requires jq for JSON parsing)
if ! command -v jq &> /dev/null; then
    log_message "ERROR" "jq is not installed. Please install jq to parse JSON."
    log_message "INFO" "=== Script ended with errors ==="
    exit 1
fi

# Extract group IDs and names
group_count=$(echo "$groups_json" | jq '. | length')
log_message "DEBUG" "Found $group_count groups"

# Extract state IDs and names
state_count=$(echo "$states_json" | jq '. | length')
log_message "DEBUG" "Found $state_count states"

# Counter for successfully indexed documents
indexed_count=0
failed_count=0

# Loop through all groups
for ((g=0; g<$group_count; g++)); do
    group_id=$(echo "$groups_json" | jq -r ".[$g].id")
    group_name=$(echo "$groups_json" | jq -r ".[$g].name")

    log_message "DEBUG" "Processing group: $group_name (ID: $group_id)"

    # Loop through all states
    for ((s=0; s<$state_count; s++)); do
        state_id=$(echo "$states_json" | jq -r ".[$s].id")
        state_name=$(echo "$states_json" | jq -r ".[$s].name")

        log_message "DEBUG" "Processing state: $state_name (ID: $state_id)"

        # Fetch ticket count for this group and state combination
        ticket_count=$(fetch_ticket_count "$group_id" "$state_name")
        fetch_result=$?

        # Only index if fetch was successful (curl didn't fail)
        if [[ $fetch_result -eq 0 ]]; then
            if index_document "$group_id" "$group_name" "$state_id" "$state_name" "$ticket_count"; then
                ((indexed_count++))
            else
                ((failed_count++))
            fi
        else
            # Only count as failed if there was an actual error (not just no tickets)
            ((failed_count++))
        fi
    done
done

# Log script completion
log_message "INFO" "Indexed $indexed_count documents successfully, $failed_count failed"
log_message "INFO" "=== Script ended ==="

exit 0
