#!/bin/bash

set -e

# Source the config file from the same directory as this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

# Functions
info() {
    echo "[INFO] $*"
}

debug() {
    if [[ "${DEBUG:-false}" == "true" ]]; then
        echo "[DEBUG] $*"
    fi
}

error() {
    echo "[ERROR] $*" >&2
}

# Validate required variables
if [[ -z "$ADO_ACCESSTOKEN" ]]; then
    error "ADO_ACCESSTOKEN is required in config.sh"
    exit 1
fi

if [[ -z "${ADO_PROJECTS_TO_SEARCH[0]}" ]]; then
    error "ADO_PROJECTS_TO_SEARCH is required in config.sh (must be an array with at least one project)"
    exit 1
fi

# Check if Python is available
if ! command -v python3 &> /dev/null; then
    error "Python 3 is required but not installed. Please install Python 3 to continue."
    exit 1
fi

# Create temp directory for JSON responses
TEMP_DIR="${TEMP_DIR:-./.temp}"
mkdir -p "$TEMP_DIR"

RETURN_CODE=0

info "Starting apps-config.yaml generation"
info "Output file: $OUTPUT_FILE"
info "Projects to search: ${ADO_PROJECTS_TO_SEARCH[*]}"

# Clear output file
> "$OUTPUT_FILE"

info "Determining repositories from Azure DevOps"

for project in "${ADO_PROJECTS_TO_SEARCH[@]}"; do
    api_get_url="${ADO_BASE_URL}/${project}/${ADO_REPO_URL_PART}"
    json_file="$TEMP_DIR/$project.json"

    info "Fetching repositories for project: $project"
    debug "curl -s -w \"%{http_code}\\n\" -H \"content-type: application/json\" -H \"Authorization: Bearer ************\" -o $json_file -X GET $api_get_url"
    
    get_response=$(curl -s -w "%{http_code}\n" -H "content-type: application/json" -H "Authorization: Bearer $ADO_ACCESSTOKEN" -o "$json_file" -X GET "$api_get_url")
    debug "GET Response: $get_response"

    if ! [ "$get_response" -eq 200 ]; then
        error "Something went wrong getting list of repositories for $project (HTTP $get_response)"
        if [ -f "$json_file" ]; then
            error "Response body:"
            cat "$json_file" >&2
        fi
        RETURN_CODE=1
        continue
    fi

    info "Processing repositories from project: $project"

    # Use Python to parse JSON and extract repository names
    repo_count=$(python3 -c "import json; data=json.load(open('$json_file')); print(data.get('count', 0))")
    info "Found $repo_count repositories in $project"

    # Extract repository names using Python
    python3 <<EOF | while IFS= read -r REPO; do
import json
import sys

with open('$json_file', 'r') as f:
    data = json.load(f)
    
for repo in data.get('value', []):
    print(repo.get('name', ''))
EOF
        # Skip empty lines
        [[ -z "$REPO" ]] && continue

        # Skip excluded repos
        if echo "$EXCLUDE_REPOS" | grep -qw "$REPO"; then
            debug "  Skipping: $REPO (excluded)"
            continue
        fi

        # Generate namespace (lowercase, replace underscores with hyphens)
        NAMESPACE=$(echo "$REPO" | tr '[:upper:]' '[:lower:]' | tr '_' '-')

        # Append to YAML file
        cat >> "$OUTPUT_FILE" <<EOF
- name: $REPO
  repo: ${ADO_BASE_URL}/${project}/_git/${REPO}
  manifests_path: $MANIFESTS_PATH
  namespace: banner
EOF

        info "Added: $REPO"
    done

done

# Clean up temp files (optional)
if [[ "${CLEANUP_TEMP:-true}" == "true" ]]; then
    debug "Cleaning up temporary files"
    rm -rf "$TEMP_DIR"
fi

# Summary
if [ -f "$OUTPUT_FILE" ]; then
    app_count=$(grep -c '^- name:' "$OUTPUT_FILE" || echo 0)
    info ""
    info "Successfully generated $OUTPUT_FILE with $app_count applications"
    info ""
    info "Next steps:"
    info "  1. Review: cat $OUTPUT_FILE"
    info "  2. Commit: git add $OUTPUT_FILE && git commit -m 'Update apps config' && git push"
else
    error "Failed to generate $OUTPUT_FILE"
    RETURN_CODE=1
fi

exit $RETURN_CODE