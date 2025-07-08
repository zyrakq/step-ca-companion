#!/bin/bash
set -e

source /app/scripts/docker-api-functions.sh

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WAIT-STEP-CA: $1"
}

wait_for_step_ca() {
    local step_ca_url="$1"
    local timeout="${STEP_CA_BOOTSTRAP_TIMEOUT:-300}"
    local max_attempts=$((timeout / 5))
    local attempt=1
    
    log "Waiting for step-ca at $step_ca_url (timeout: ${timeout}s)..."
    
    while [ $attempt -le $max_attempts ]; do
        # Check health endpoint
        if curl -k -s --max-time 5 "$step_ca_url/health" > /dev/null 2>&1; then
            # Also check ACME endpoint
            if curl -k -s --max-time 5 "$step_ca_url/acme/acme/directory" | grep -q "newNonce" 2>/dev/null; then
                log "step-ca is fully available (health + ACME endpoints ready)"
                return 0
            else
                log "step-ca health OK, but ACME endpoint not ready yet (attempt $attempt/$max_attempts)"
            fi
        else
            log "step-ca health endpoint not ready (attempt $attempt/$max_attempts)"
        fi
        
        if [ $attempt -lt $max_attempts ]; then
            sleep 5
            attempt=$((attempt + 1))
        else
            break
        fi
    done
    
    log "ERROR: step-ca is unavailable after $max_attempts attempts"
    return 1
}

# If script is called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ -n "${1:-}" ]]; then
        wait_for_step_ca "$1"
    else
        echo "Usage: $0 <step_ca_url>"
        exit 1
    fi
fi