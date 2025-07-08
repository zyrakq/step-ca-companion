#!/bin/bash

set -e

# Import functions
source /app/scripts/trust-functions.sh

# Configuration
STEP_CA_CONTAINER_NAME=${STEP_CA_CONTAINER_NAME:-"step-ca"}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] TRUST-PROCESSOR: $1"
}

process_trust_certificate() {
    local container_id="$1"
    local container_name="$2"
    
    log "Processing trust certificate for container: $container_name (ID: $container_id)"
    
    # Check if container exists and is running using Docker API
    if ! is_container_running "$container_id"; then
        log "WARNING: Container $container_id is not running, skipping"
        return 0
    fi
    
    # Install trust certificate in the container
    if install_trust_certificate "$container_id" "$container_name"; then
        log "Trust certificate successfully installed in container: $container_name"
    else
        log "ERROR: Failed to install trust certificate in container: $container_name"
    fi
}

# Set Docker socket path for API calls
export DOCKER_HOST=unix:///var/run/docker.sock

# Check step-ca availability
if ! check_step_ca_availability; then
    log "ERROR: step-ca is not available"
    exit 1
fi

# Execute generated script
if [ -f "/tmp/trust-containers.sh" ]; then
    log "Executing generated trust certificate script"
    source /tmp/trust-containers.sh
else
    log "No trust certificate script found, nothing to process"
fi

log "Trust certificate processing completed"