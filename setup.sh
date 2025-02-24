#!/bin/bash
set -e

##############################
# Helper: Check for required tools
##############################
check_required_tools() {
    if ! command -v jq &> /dev/null; then
        echo "jq is not installed. Please install jq to use this action."
        exit 1
    fi

    if ! command -v openssl &> /dev/null; then
        echo "openssl is not installed. Please install openssl to use this action."
        exit 1
    fi
}
check_required_tools

##############################
# Validate required inputs
##############################
# WARPBUILD_RUNNER_VERIFICATION_TOKEN must be set.
if [ -z "$WARPBUILD_RUNNER_VERIFICATION_TOKEN" ]; then
    echo "WARPBUILD_RUNNER_VERIFICATION_TOKEN is not set"
    exit 1
fi

# Determine runner type.
# If the token is not exactly "true", assume it's a WarpBuild runner.
IS_WARPBUILD_RUNNER=false
if [ "$WARPBUILD_RUNNER_VERIFICATION_TOKEN" != "true" ]; then
    IS_WARPBUILD_RUNNER=true
fi

# Profile name is required.
if [ -z "$INPUT_PROFILE_NAME" ]; then
    echo "Profile name (INPUT_PROFILE_NAME) is required"
    exit 1
fi

# For non-WarpBuild runners, API key is required.
if [ "$IS_WARPBUILD_RUNNER" = false ] && [ -z "$INPUT_API_KEY" ]; then
    echo "API key (INPUT_API_KEY) is required for non-WarpBuild runners"
    exit 1
fi

# Set timeout (milliseconds). Default to 30000 if not provided.
TIMEOUT=${INPUT_TIMEOUT:-30000}

# Optional: if INPUT_PLATFORMS is not provided, default to linux/amd64,linux/arm64
DEFAULT_PLATFORMS="linux/amd64,linux/arm64"

##############################
# Variables for API call
##############################
MAX_RETRIES=5
RETRY_WAIT=10
TEMP_RESPONSE="/tmp/warpbuild_response.json"
ASSIGN_BUILDER_ENDPOINT="https://api.warpbuild.com/api/v1/runners/builders/assign"

# Prepare the appropriate auth header.
if [ "$IS_WARPBUILD_RUNNER" = true ]; then
    AUTH_HEADER="Authorization: Bearer $WARPBUILD_RUNNER_VERIFICATION_TOKEN"
else
    AUTH_HEADER="Authorization: Bearer $INPUT_API_KEY"
fi

##############################
# API Request: Assign Builder
##############################
for ((i=1; i<=MAX_RETRIES; i++)); do
    RESPONSE=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        -H "$AUTH_HEADER" \
        -d "{\"profile_id\": \"$INPUT_PROFILE_NAME\"}" \
        "$ASSIGN_BUILDER_ENDPOINT")

    # Save the API response
    echo "$RESPONSE" > "$TEMP_RESPONSE"

    # Check if response contains builder instances.
    if [ $? -eq 0 ] && [ "$(jq 'has(\"builder_instances\")' "$TEMP_RESPONSE")" = "true" ] && \
       [ "$(jq '.builder_instances | length' "$TEMP_RESPONSE")" -gt 0 ]; then
        break
    fi

    if [ $i -eq $MAX_RETRIES ]; then
        echo "Failed to assign builder after $MAX_RETRIES attempts"
        exit 1
    fi

    echo "Retry $i failed, waiting $RETRY_WAIT seconds..."
    sleep $RETRY_WAIT
done

##############################
# Function: Wait for Builder
##############################
# This function checks two things:
#   1. The server is reachable via ping
#   2. The Docker daemon port is accepting TLS connections
#
# It assumes that $BUILDER_HOST and $CERT_DIR (with ca.pem, cert.pem, key.pem) are defined.
wait_for_builder() {
    local builder_id=$1
    local start_time
    start_time=$(date +%s000)  # current time in milliseconds

    # Extract IP and port from BUILDER_HOST
    local server_ip
    local server_port
    server_ip=$(echo "$BUILDER_HOST" | sed -E 's|^tcp://||' | cut -d: -f1)
    server_port=$(echo "$BUILDER_HOST" | sed -E 's|^tcp://||' | cut -d: -f2)
    # Default to 2376 if no port specified (standard Docker TLS port)
    server_port=${server_port:-2376}

    while true; do
        local current_time
        current_time=$(date +%s000)
        local elapsed=$((current_time - start_time))

        if [ $elapsed -gt $TIMEOUT ]; then
            echo "Timeout waiting for builder to be ready after ${TIMEOUT}ms"
            exit 1
        fi

        # Check if server is reachable
        if ! ping -c 1 -W 2 "$server_ip" > /dev/null 2>&1; then
            echo "Builder server $server_ip is not reachable"
            sleep 2
            continue
        fi

        # Check if the port is accepting TLS connections
        if openssl s_client -connect "${server_ip}:${server_port}" \
            -CAfile "$CERT_DIR/ca.pem" \
            -cert "$CERT_DIR/cert.pem" \
            -key "$CERT_DIR/key.pem" \
            -quiet \
            -verify_return_error </dev/null >/dev/null 2>&1; then
            echo "Builder is ready and accepting TLS connections"
            return 0
        else
            echo "Builder port ${server_port} is not accepting TLS connections yet"
        fi

        sleep 2
    done
}

##############################
# Extract Builder Information
##############################
# Extract and validate details from the first builder instance
BUILDER_ID=$(jq -r '.builder_instances[0].id' "$TEMP_RESPONSE")
if [ -z "$BUILDER_ID" ] || [ "$BUILDER_ID" = "null" ]; then
    echo "Failed to extract builder ID from response"
    exit 1
fi

BUILDER_HOST=$(jq -r '.builder_instances[0].metadata.host' "$TEMP_RESPONSE")
if [ -z "$BUILDER_HOST" ] || [ "$BUILDER_HOST" = "null" ]; then
    echo "Failed to extract builder host from response"
    exit 1
fi

BUILDER_CA=$(jq -r '.builder_instances[0].metadata.ca' "$TEMP_RESPONSE")
BUILDER_CLIENT_CERT=$(jq -r '.builder_instances[0].metadata.client_cert' "$TEMP_RESPONSE")
BUILDER_CLIENT_KEY=$(jq -r '.builder_instances[0].metadata.client_key' "$TEMP_RESPONSE")

# Validate certificates are present
if [ -z "$BUILDER_CA" ] || [ "$BUILDER_CA" = "null" ] || \
   [ -z "$BUILDER_CLIENT_CERT" ] || [ "$BUILDER_CLIENT_CERT" = "null" ] || \
   [ -z "$BUILDER_CLIENT_KEY" ] || [ "$BUILDER_CLIENT_KEY" = "null" ]; then
    echo "Failed to extract certificates from response"
    exit 1
fi

# If the API returned a platforms field, use it; otherwise, default.
BUILDER_PLATFORMS=$(jq -r '.builder_instances[0].metadata.platforms // empty' "$TEMP_RESPONSE")
if [ -z "$BUILDER_PLATFORMS" ]; then
    BUILDER_PLATFORMS="$DEFAULT_PLATFORMS"
fi

# Check if there's a second builder instance
BUILDER_COUNT=$(jq '.builder_instances | length' "$TEMP_RESPONSE")
if [ "$BUILDER_COUNT" -gt 1 ]; then
    BUILDER_1_ID=$(jq -r '.builder_instances[1].id' "$TEMP_RESPONSE")
    BUILDER_1_HOST=$(jq -r '.builder_instances[1].metadata.host' "$TEMP_RESPONSE")
    BUILDER_1_CA=$(jq -r '.builder_instances[1].metadata.ca' "$TEMP_RESPONSE")
    BUILDER_1_CLIENT_CERT=$(jq -r '.builder_instances[1].metadata.client_cert' "$TEMP_RESPONSE")
    BUILDER_1_CLIENT_KEY=$(jq -r '.builder_instances[1].metadata.client_key' "$TEMP_RESPONSE")
    BUILDER_1_PLATFORMS=$(jq -r '.builder_instances[1].metadata.platforms // empty' "$TEMP_RESPONSE")
    if [ -z "$BUILDER_1_PLATFORMS" ]; then
        BUILDER_1_PLATFORMS="$DEFAULT_PLATFORMS"
    fi
fi

##############################
# Setup TLS Certificates
##############################
CERT_DIR=$(mktemp -d)
if ! echo "$BUILDER_CA" | base64 -d > "$CERT_DIR/ca.pem"; then
    echo "Failed to decode CA certificate"
    rm -rf "$CERT_DIR"
    exit 1
fi
if ! echo "$BUILDER_CLIENT_CERT" | base64 -d > "$CERT_DIR/cert.pem"; then
    echo "Failed to decode client certificate"
    rm -rf "$CERT_DIR"
    exit 1
fi
if ! echo "$BUILDER_CLIENT_KEY" | base64 -d > "$CERT_DIR/key.pem"; then
    echo "Failed to decode client key"
    rm -rf "$CERT_DIR"
    exit 1
fi

if [ "$BUILDER_COUNT" -gt 1 ]; then
    CERT_DIR_1=$(mktemp -d)
    if ! echo "$BUILDER_1_CA" | base64 -d > "$CERT_DIR_1/ca.pem" || \
       ! echo "$BUILDER_1_CLIENT_CERT" | base64 -d > "$CERT_DIR_1/cert.pem" || \
       ! echo "$BUILDER_1_CLIENT_KEY" | base64 -d > "$CERT_DIR_1/key.pem"; then
        echo "Failed to decode certificates for second builder"
        rm -rf "$CERT_DIR" "$CERT_DIR_1"
        exit 1
    fi
fi

##############################
# Wait Until Builder(s) & Docker Are Ready
##############################
echo "Waiting for builder 0 to be ready..."
BUILDER_HOST="$BUILDER_HOST" CERT_DIR="$CERT_DIR" wait_for_builder "$BUILDER_ID"

if [ "$BUILDER_COUNT" -gt 1 ]; then
    echo "Waiting for builder 1 to be ready..."
    BUILDER_HOST="$BUILDER_1_HOST" CERT_DIR="$CERT_DIR_1" wait_for_builder "$BUILDER_1_ID"
fi

##############################
# Set Outputs for Composite Action
##############################
{
    echo "docker-builder-node-0-endpoint=$BUILDER_HOST"
    echo "docker-builder-node-0-platforms=$BUILDER_PLATFORMS"
    echo "docker-builder-node-0-cacert=$BUILDER_CA"
    echo "docker-builder-node-0-cert=$BUILDER_CLIENT_CERT"
    echo "docker-builder-node-0-key=$BUILDER_CLIENT_KEY"

    if [ "$BUILDER_COUNT" -gt 1 ]; then
        echo "docker-builder-node-1-endpoint=$BUILDER_1_HOST"
        echo "docker-builder-node-1-platforms=$BUILDER_1_PLATFORMS"
        echo "docker-builder-node-1-cacert=$BUILDER_1_CA"
        echo "docker-builder-node-1-cert=$BUILDER_1_CLIENT_CERT"
        echo "docker-builder-node-1-key=$BUILDER_1_CLIENT_KEY"
    else
        echo "docker-builder-node-1-endpoint="
        echo "docker-builder-node-1-platforms="
        echo "docker-builder-node-1-cacert="
        echo "docker-builder-node-1-cert="
        echo "docker-builder-node-1-key="
    fi
} >> "$GITHUB_OUTPUT"

##############################
# Cleanup
##############################
rm -rf "$CERT_DIR"
if [ "$BUILDER_COUNT" -gt 1 ]; then
    rm -rf "$CERT_DIR_1"
fi
rm -f "$TEMP_RESPONSE"