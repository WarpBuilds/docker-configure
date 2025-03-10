#!/bin/bash
set -e

# Record script start time (milliseconds)
SCRIPT_START_TIME=$(date +%s000)

# Check global timeout - call this function regularly
check_global_timeout() {
    local current_time
    current_time=$(date +%s000)
    local total_elapsed=$((current_time - SCRIPT_START_TIME))

    if [ $total_elapsed -gt $TIMEOUT ]; then
        echo "ERROR: Global script timeout of ${TIMEOUT}ms exceeded after ${total_elapsed}ms"
        echo "Script execution terminated"
        exit 1
    fi
}

##############################
# Helper: Check for required tools
##############################
check_required_tools() {
    if ! command -v jq &> /dev/null; then
        echo "jq is not installed. Please install jq to use this action."
        exit 1
    fi

    if ! command -v curl &> /dev/null; then
        echo "curl is not installed. Please install curl to use this action."
        exit 1
    fi
}
check_required_tools

##############################
# Validate required inputs
##############################
# Either WARPBUILD_RUNNER_VERIFICATION_TOKEN or INPUT_API_KEY must be set
if [ -z "$WARPBUILD_RUNNER_VERIFICATION_TOKEN" ] && [ -z "$INPUT_API_KEY" ]; then
    echo "Either WARPBUILD_RUNNER_VERIFICATION_TOKEN or INPUT_API_KEY must be set"
    exit 1
fi

# Determine runner type.
# If verification token is set and not "true", assume it's a WarpBuild runner.
IS_WARPBUILD_RUNNER=false
if [ -n "$WARPBUILD_RUNNER_VERIFICATION_TOKEN" ] && [ "$WARPBUILD_RUNNER_VERIFICATION_TOKEN" != "true" ]; then
    IS_WARPBUILD_RUNNER=true
fi

# Profile name is required.
if [ -z "${INPUT_PROFILE_NAME}" ]; then
    echo "Profile name (INPUT_PROFILE_NAME) is required"
    exit 1
fi

# For non-WarpBuild runners, API key is required.
if [ "$IS_WARPBUILD_RUNNER" = false ] && [ -z "$INPUT_API_KEY" ]; then
    echo "API key (INPUT_API_KEY) is required for non-WarpBuild runners"
    exit 1
fi

# Set timeout (milliseconds). Default to 200000 if not provided.
TIMEOUT="${INPUT_TIMEOUT:-200000}"
echo "Global script timeout set to ${TIMEOUT}ms"

# Optional: if INPUT_PLATFORMS is not provided, default to linux/amd64,linux/arm64
DEFAULT_PLATFORMS="linux/amd64,linux/arm64"

##############################
# OS-independent temp directory and port check
##############################
# Get temp directory in a portable way
get_temp_dir() {
    if [ -n "$RUNNER_TEMP" ]; then
        echo "$RUNNER_TEMP"
    elif [ -n "$TMPDIR" ]; then
        echo "$TMPDIR"
    elif [ -d "/tmp" ]; then
        echo "/tmp"
    else
        echo "."
    fi
}

# Create temp directory with unique name
create_temp_dir() {
    local temp_base
    temp_base="$(get_temp_dir)/warpbuild_$(date +%s)_$RANDOM"
    mkdir -p "$temp_base"
    echo "$temp_base"
}

# Docker connection check that bypasses strict certificate verification
check_port_available() {
    local host=$1
    local port=$2
    local cert_dir=$3

    echo "Testing Docker connection to ${host}:${port} with TLS certificates..."

    # We'll disable errexit within this function too
    set +e

    curl --connect-timeout 5 --max-time 10 \
        --cacert "$cert_dir/ca.pem" \
        --cert "$cert_dir/cert.pem" \
        --key "$cert_dir/key.pem" \
        -s "https://${host}:${port}/version" >/dev/null 2>&1
    local result=$?

    if [ $result -eq 0 ]; then
        echo "✓ Docker API connection successful"
        set -e  # Restore errexit
        return 0
    else
        echo "✗ Docker connection failed (error: $result)"
        set -e  # Restore errexit
        return 1
    fi
}

##############################
# Variables for API call
##############################
TEMP_DIR=$(create_temp_dir)
TEMP_RESPONSE="$TEMP_DIR/response.json"
MAX_RETRIES=5
RETRY_WAIT=10

# Set API domain - use environment variable if provided, otherwise use production
WARPBUILD_API_DOMAIN="${WARPBUILD_API_DOMAIN:-https://api.warpbuild.com}"

# Construct API endpoints using the domain
ASSIGN_BUILDER_ENDPOINT="${WARPBUILD_API_DOMAIN}/api/v1/builders/assign"
BUILDER_DETAILS_ENDPOINT="${WARPBUILD_API_DOMAIN}/api/v1/builders"

##############################
# Function: Wait for Builder Details
##############################
wait_for_builder_details() {
    local builder_id=$1
    local start_time
    start_time=$(date +%s000)

    # Disable errexit for retry logic
    set +e

    while true; do
        # Check global timeout first
        check_global_timeout

        local current_time
        current_time=$(date +%s000)
        local elapsed=$((current_time - start_time))

        if [ $elapsed -gt $TIMEOUT ]; then
            echo "Timeout waiting for builder $builder_id to be ready after ${TIMEOUT}ms"
            set -e  # Restore errexit
            exit 1
        fi

        # Get builder details with error handling
        {
            local details_response
            details_response=$(curl -s --connect-timeout 5 --max-time 10 -H "$AUTH_HEADER" "${BUILDER_DETAILS_ENDPOINT}/${builder_id}/details")

            # Save to temporary file for jq processing
            echo "$details_response" > "$TEMP_DIR/builder_${builder_id}_details.json"

            # Extract status safely
            local status
            status=$(jq -r '.status // "unknown"' "$TEMP_DIR/builder_${builder_id}_details.json" || echo "unknown")
            local host
            host=$(jq -r '.metadata.host // ""' "$TEMP_DIR/builder_${builder_id}_details.json" || echo "")
        } || true

        # Check if response is valid JSON (run outside the block to handle normally)
        if ! jq -e . "$TEMP_DIR/builder_${builder_id}_details.json" > /dev/null 2>&1; then
            echo "Invalid JSON response from details endpoint"
            cat "$TEMP_DIR/builder_${builder_id}_details.json"
            sleep 2
            continue
        fi

        if [ "$status" = "ready" ]; then
            # Validate host is present
            if [ -z "$host" ] || [ "$host" = "null" ]; then
                echo "Builder $builder_id is ready but host information is missing"
                set -e  # Restore errexit
                exit 1
            fi

            echo "Builder $builder_id is ready"
            echo "$details_response" > "$TEMP_DIR/builder_${builder_id}_final.json"
            set -e  # Restore errexit
            return 0
        elif [ "$status" = "failed" ]; then
            echo "Builder $builder_id failed to initialize"
            set -e  # Restore errexit
            exit 1
        fi

        echo "Builder $builder_id status: $status. Waiting..."
        sleep 2
        rm -f "$TEMP_DIR/builder_${builder_id}_details.json"
    done

    # This should never be reached, but just in case
    set -e
}

##############################
# Function: Wait for Docker Port
##############################
wait_for_docker_port() {
    local host=$1
    local cert_dir=$2
    local start_time
    start_time=$(date +%s000)

    # Disable errexit for retry logic
    set +e

    # Extract IP and port from host
    local server_ip
    local server_port
    server_ip=$(echo "$host" | sed -E 's|^tcp://||' | cut -d: -f1)
    server_port=$(echo "$host" | sed -E 's|^tcp://||' | cut -d: -f2)
    # Default to 2376 if no port specified (standard Docker TLS port)
    server_port=${server_port:-2376}

    echo "Waiting for Docker port ${server_port} on ${server_ip}..."

    while true; do
        # Check global timeout first
        check_global_timeout

        local current_time
        current_time=$(date +%s000)
        local elapsed=$((current_time - start_time))

        if [ $elapsed -gt $TIMEOUT ]; then
            echo "Timeout waiting for Docker port after ${TIMEOUT}ms"
            set -e  # Restore errexit
            exit 1
        fi

        # Try to connect, but don't exit on failure
        if check_port_available "$server_ip" "$server_port" "$cert_dir"; then
            echo "Docker daemon is now available"
            set -e  # Restore errexit
            return 0
        fi

        echo "Docker daemon not available yet. Retrying..."
        sleep 2
    done

    # This should never be reached, but just in case
    set -e
}

##############################
# API Request: Assign Builder with Static Retry Delay
##############################
# Prepare the appropriate auth header.
if [ "$IS_WARPBUILD_RUNNER" = true ]; then
    AUTH_HEADER="Authorization: Bearer $WARPBUILD_RUNNER_VERIFICATION_TOKEN"
else
    AUTH_HEADER="Authorization: Bearer $INPUT_API_KEY"
fi

# Save current errexit option state and disable it for retry logic
set +e
# Call the assign builders endpoint with static retry delay
MAX_RETRIES=30
STATIC_WAIT=5  # Fixed 5-second wait between all retries

for ((i=1; i<=MAX_RETRIES; i++)); do
    # Check global timeout
    check_global_timeout

    echo "Making API request to assign builder (attempt $i of $MAX_RETRIES)..."

    # Use curl to get the HTTP status and save response
    HTTP_STATUS=$(curl -s -X POST \
        -w "%{http_code}" \
        -o "$TEMP_RESPONSE" \
        -H "Content-Type: application/json" \
        -H "$AUTH_HEADER" \
        -d "{\"profile_name\": \"$INPUT_PROFILE_NAME\"}" \
        "$ASSIGN_BUILDER_ENDPOINT")

    # Check if response is valid JSON before trying to parse it
    if jq empty "$TEMP_RESPONSE" 2>/dev/null; then
        # Valid JSON - check if successful response with builder instances
        if [[ $HTTP_STATUS =~ ^2[0-9][0-9]$ ]] && \
           jq -e 'has("builder_instances")' "$TEMP_RESPONSE" >/dev/null 2>&1 && \
           [ "$(jq '.builder_instances | length' "$TEMP_RESPONSE")" -gt 0 ]; then
            echo "✓ Successfully assigned builder(s)"
            break
        fi

        # Extract error information from valid JSON
        ERROR_CODE=$(jq -r '.code // "unknown"' "$TEMP_RESPONSE")
        ERROR_MESSAGE=$(jq -r '.message // "Unknown error"' "$TEMP_RESPONSE")
        ERROR_DESCRIPTION=$(jq -r '.description // "No description provided"' "$TEMP_RESPONSE")
    else
        # Not valid JSON - use HTTP status as the error information
        echo "WARNING: Server returned non-JSON response"
        cat "$TEMP_RESPONSE"
        ERROR_CODE="unknown"
        ERROR_MESSAGE="Non-JSON response received"
        ERROR_DESCRIPTION="HTTP status code: $HTTP_STATUS"
    fi

    # Only retry on 5xx (server errors), 409 (conflict), and 429 (rate limit)
    if [[ ! $HTTP_STATUS =~ ^5[0-9][0-9]$ ]] && [ "$HTTP_STATUS" != "409" ] && [ "$HTTP_STATUS" != "429" ]; then
        echo "API Error: HTTP Status $HTTP_STATUS"
        echo "Error details: [$ERROR_CODE] $ERROR_MESSAGE"
        echo "Error description: $ERROR_DESCRIPTION"
        echo "Not a retriable error. Aborting."
        exit 1
    fi

    if [ $i -eq $MAX_RETRIES ]; then
        echo "API Error: HTTP Status $HTTP_STATUS"
        echo "Error details: [$ERROR_CODE] $ERROR_MESSAGE"
        echo "Error description: $ERROR_DESCRIPTION"
        echo "Failed to assign builder after $MAX_RETRIES attempts"
        exit 1
    fi

    # Use static wait time instead of exponential backoff
    echo "Assign builder failed: HTTP Status $HTTP_STATUS - $ERROR_DESCRIPTION"
    echo "Waiting ${STATIC_WAIT} seconds before next attempt..."
    sleep $STATIC_WAIT
done
# Restore original errexit state
set -e

##############################
# Extract Initial Builder IDs
##############################
BUILDER_COUNT=$(jq '.builder_instances | length' "$TEMP_RESPONSE")
BUILDER_ID=$(jq -r '.builder_instances[0].id' "$TEMP_RESPONSE")
if [ -z "$BUILDER_ID" ] || [ "$BUILDER_ID" = "null" ]; then
    echo "Failed to extract builder ID from response"
    exit 1
fi

if [ "$BUILDER_COUNT" -gt 1 ]; then
    BUILDER_1_ID=$(jq -r '.builder_instances[1].id' "$TEMP_RESPONSE")
    if [ -z "$BUILDER_1_ID" ] || [ "$BUILDER_1_ID" = "null" ]; then
        echo "Failed to extract second builder ID from response"
        exit 1
    fi
fi

##############################
# Wait for Builders and Setup
##############################
# First builder
echo "Waiting for builder 0 ($BUILDER_ID) to be ready..."
wait_for_builder_details "$BUILDER_ID"

# Extract information from the final details - fixing jq paths
BUILDER_HOST=$(jq -r '.metadata.host' "$TEMP_DIR/builder_${BUILDER_ID}_final.json")
BUILDER_CA=$(jq -r '.metadata.ca' "$TEMP_DIR/builder_${BUILDER_ID}_final.json")
BUILDER_CLIENT_CERT=$(jq -r '.metadata.client_cert' "$TEMP_DIR/builder_${BUILDER_ID}_final.json")
BUILDER_CLIENT_KEY=$(jq -r '.metadata.client_key' "$TEMP_DIR/builder_${BUILDER_ID}_final.json")
BUILDER_PLATFORMS=$(jq -r '.arch // empty' "$TEMP_DIR/builder_${BUILDER_ID}_final.json")
if [ -z "$BUILDER_PLATFORMS" ]; then
    BUILDER_PLATFORMS="$DEFAULT_PLATFORMS"
fi

# Format the platform with "linux/" prefix
if [ -n "$BUILDER_PLATFORMS" ]; then
    # Check if it already contains "linux/"
    if [[ "$BUILDER_PLATFORMS" != *"linux/"* ]]; then
        # Handle comma-separated values
        BUILDER_PLATFORMS=$(echo "$BUILDER_PLATFORMS" | sed 's/\([^,]*\)/linux\/\1/g')
    fi
else
    BUILDER_PLATFORMS="$DEFAULT_PLATFORMS"
fi

# Setup TLS certificates for first builder
CERT_DIR=$(mktemp -d)
echo "$BUILDER_CA" > "$CERT_DIR/ca.pem"
echo "$BUILDER_CLIENT_CERT" > "$CERT_DIR/cert.pem"
echo "$BUILDER_CLIENT_KEY" > "$CERT_DIR/key.pem"
# Check if files were created properly
if [ ! -s "$CERT_DIR/ca.pem" ] || [ ! -s "$CERT_DIR/cert.pem" ] || [ ! -s "$CERT_DIR/key.pem" ]; then
    echo "Failed to write certificate files"
    rm -rf "$CERT_DIR"
    exit 1
fi

# Wait for Docker port to be available
wait_for_docker_port "$BUILDER_HOST" "$CERT_DIR"

# Second builder (if available)
if [ "$BUILDER_COUNT" -gt 1 ]; then
    echo "Waiting for builder 1 ($BUILDER_1_ID) to be ready..."
    wait_for_builder_details "$BUILDER_1_ID"

    # Extract information for second builder
    BUILDER_1_HOST=$(jq -r '.metadata.host' "$TEMP_DIR/builder_${BUILDER_1_ID}_final.json")
    BUILDER_1_CA=$(jq -r '.metadata.ca' "$TEMP_DIR/builder_${BUILDER_1_ID}_final.json")
    BUILDER_1_CLIENT_CERT=$(jq -r '.metadata.client_cert' "$TEMP_DIR/builder_${BUILDER_1_ID}_final.json")
    BUILDER_1_CLIENT_KEY=$(jq -r '.metadata.client_key' "$TEMP_DIR/builder_${BUILDER_1_ID}_final.json")
    BUILDER_1_PLATFORMS=$(jq -r '.arch // empty' "$TEMP_DIR/builder_${BUILDER_1_ID}_final.json")
    if [ -z "$BUILDER_1_PLATFORMS" ]; then
        BUILDER_1_PLATFORMS="$DEFAULT_PLATFORMS"
    fi

    # Format the platform with "linux/" prefix
    if [ -n "$BUILDER_1_PLATFORMS" ]; then
        # Check if it already contains "linux/"
        if [[ "$BUILDER_1_PLATFORMS" != *"linux/"* ]]; then
            # Handle comma-separated values
            BUILDER_1_PLATFORMS=$(echo "$BUILDER_1_PLATFORMS" | sed 's/\([^,]*\)/linux\/\1/g')
        fi
    else
        BUILDER_1_PLATFORMS="$DEFAULT_PLATFORMS"
    fi

    # Setup TLS certificates for second builder
    CERT_DIR_1=$(mktemp -d)
    echo "$BUILDER_1_CA" > "$CERT_DIR_1/ca.pem"
    echo "$BUILDER_1_CLIENT_CERT" > "$CERT_DIR_1/cert.pem"
    echo "$BUILDER_1_CLIENT_KEY" > "$CERT_DIR_1/key.pem"
    # Check if files were created properly
    if [ ! -s "$CERT_DIR_1/ca.pem" ] || [ ! -s "$CERT_DIR_1/cert.pem" ] || [ ! -s "$CERT_DIR_1/key.pem" ]; then
        echo "Failed to write certificate files for second builder"
        rm -rf "$CERT_DIR" "$CERT_DIR_1"
        exit 1
    fi

    # Wait for second builder's Docker port
    wait_for_docker_port "$BUILDER_1_HOST" "$CERT_DIR_1"
fi

##############################
# Set Outputs for GitHub Actions
##############################
# Write outputs directly to GITHUB_OUTPUT
# Single-line outputs can remain as-is:
echo "docker-builder-node-0-endpoint=${BUILDER_HOST}" >> "$GITHUB_OUTPUT"
echo "docker-builder-node-0-platforms=${BUILDER_PLATFORMS}" >> "$GITHUB_OUTPUT"

# For multi-line outputs (certificates), use the heredoc syntax:
echo "docker-builder-node-0-cacert<<EOF" >> "$GITHUB_OUTPUT"
echo "$BUILDER_CA" >> "$GITHUB_OUTPUT"
echo "EOF" >> "$GITHUB_OUTPUT"

echo "docker-builder-node-0-cert<<EOF" >> "$GITHUB_OUTPUT"
echo "$BUILDER_CLIENT_CERT" >> "$GITHUB_OUTPUT"
echo "EOF" >> "$GITHUB_OUTPUT"

echo "docker-builder-node-0-key<<EOF" >> "$GITHUB_OUTPUT"
echo "$BUILDER_CLIENT_KEY" >> "$GITHUB_OUTPUT"
echo "EOF" >> "$GITHUB_OUTPUT"

if [ "$BUILDER_COUNT" -gt 1 ]; then
    echo "docker-builder-node-1-endpoint=${BUILDER_1_HOST}" >> "$GITHUB_OUTPUT"
    echo "docker-builder-node-1-platforms=${BUILDER_1_PLATFORMS}" >> "$GITHUB_OUTPUT"

    echo "docker-builder-node-1-cacert<<EOF" >> "$GITHUB_OUTPUT"
    echo "$BUILDER_1_CA" >> "$GITHUB_OUTPUT"
    echo "EOF" >> "$GITHUB_OUTPUT"

    echo "docker-builder-node-1-cert<<EOF" >> "$GITHUB_OUTPUT"
    echo "$BUILDER_1_CLIENT_CERT" >> "$GITHUB_OUTPUT"
    echo "EOF" >> "$GITHUB_OUTPUT"

    echo "docker-builder-node-1-key<<EOF" >> "$GITHUB_OUTPUT"
    echo "$BUILDER_1_CLIENT_KEY" >> "$GITHUB_OUTPUT"
    echo "EOF" >> "$GITHUB_OUTPUT"
fi

##############################
# Cleanup
##############################
rm -rf "$TEMP_DIR" "$CERT_DIR"  # Clean up all temporary directories
if [ "$BUILDER_COUNT" -gt 1 ]; then
    rm -rf "$CERT_DIR_1"
fi