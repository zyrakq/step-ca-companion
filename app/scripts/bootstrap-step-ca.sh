#!/bin/bash
set -e

source /app/scripts/docker-api-functions.sh
source /app/scripts/wait-for-step-ca.sh

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] BOOTSTRAP: $1"
}

get_fingerprint_via_api() {
    local step_ca_url="$1"
    local temp_cert="/tmp/step-ca-root.crt"
    
    log "Getting fingerprint via API..."
    
    if curl -k -s --max-time 10 "$step_ca_url/roots" | jq -r '.crts[0]' > "$temp_cert" 2>/dev/null; then
        if grep -q "BEGIN CERTIFICATE" "$temp_cert"; then
            local fingerprint
            if fingerprint=$(step certificate fingerprint "$temp_cert" 2>/dev/null); then
                log "Successfully got fingerprint via API"
                rm -f "$temp_cert"
                echo "$fingerprint"
                return 0
            fi
        fi
    fi
    
    rm -f "$temp_cert"
    log "ERROR: Failed to get fingerprint via API"
    return 1
}

get_fingerprint_via_docker() {
    local step_ca_container="$1"
    
    log "Getting fingerprint via Docker exec..."
    
    local fingerprint
    if fingerprint=$(docker exec "$step_ca_container" step certificate fingerprint /home/step/certs/root_ca.crt 2>/dev/null); then
        log "Successfully got fingerprint via Docker exec"
        echo "$fingerprint"
        return 0
    fi
    
    log "WARNING: Failed to get fingerprint via Docker exec"
    return 1
}

get_step_ca_params() {
    local step_ca_container
    local step_ca_url
    local step_ca_fingerprint
    
    log "Auto-discovering step-ca parameters..."
    
    # 1. step-ca container discovery
    step_ca_container=$(get_step_ca_container)
    if [[ -z "$step_ca_container" ]]; then
        log "ERROR: step-ca container not found"
        return 1
    fi
    
    log "Found step-ca container: $step_ca_container"
    
    # Check that container is running
    if ! is_container_running "$step_ca_container"; then
        log "ERROR: step-ca container is not running"
        return 1
    fi
    
    # 2. URL formation
    local container_name
    container_name=$(get_container_name "$step_ca_container")
    step_ca_url="https://${container_name}:9000"
    
    log "step-ca URL: $step_ca_url"
    
    # 3. Wait for step-ca readiness
    if ! wait_for_step_ca "$step_ca_url"; then
        log "ERROR: step-ca is not ready"
        return 1
    fi
    
    # 4. Get fingerprint (with fallback)
    # Method 1: Via Docker exec (faster and more reliable)
    if step_ca_fingerprint=$(get_fingerprint_via_docker "$step_ca_container"); then
        log "Got fingerprint via Docker exec"
    # Method 2: Via API (fallback)
    elif step_ca_fingerprint=$(get_fingerprint_via_api "$step_ca_url"); then
        log "Got fingerprint via API"
    else
        log "ERROR: Could not get step-ca fingerprint"
        return 1
    fi
    
    # Export variables
    export STEP_CA_URL="$step_ca_url"
    export STEP_CA_FINGERPRINT="$step_ca_fingerprint"
    
    log "step-ca URL: $STEP_CA_URL"
    log "step-ca fingerprint: $STEP_CA_FINGERPRINT"
    
    return 0
}

bootstrap_step_ca() {
    log "Starting step-ca bootstrap process..."
    
    # Use provided variables or auto-discover
    if [[ -n "${STEP_CA_URL:-}" && -n "${STEP_CA_FINGERPRINT:-}" ]]; then
        log "Using provided step-ca parameters"
        log "step-ca URL: $STEP_CA_URL"
        log "step-ca fingerprint: $STEP_CA_FINGERPRINT"
    else
        log "Auto-discovering step-ca parameters..."
        if ! get_step_ca_params; then
            log "ERROR: Failed to get step-ca parameters"
            return 1
        fi
    fi
    
    # Download and install root certificate directly via API
    log "Downloading root certificate from step-ca API: $STEP_CA_URL"
    local temp_cert="/tmp/step-ca-root.crt"
    
    if curl -k -s --max-time 10 "$STEP_CA_URL/roots" | jq -r '.crts[0]' > "$temp_cert" 2>/dev/null; then
        if grep -q "BEGIN CERTIFICATE" "$temp_cert"; then
            log "Successfully downloaded root certificate"
            
            # Install root certificate in Alpine Linux
            log "Installing root certificate in Alpine Linux trust store..."
            
            # Create directory if it doesn't exist
            mkdir -p /etc/ssl/certs
            
            # Copy certificate
            cp "$temp_cert" /etc/ssl/certs/step-ca-root.crt
            
            # Add to certificate bundle
            cat "$temp_cert" >> /etc/ssl/certs/ca-certificates.crt
            
            log "Root certificate installed successfully"
            
            # Clean up temporary file
            rm -f "$temp_cert"
            
            # Verify trust installation
            log "Verifying trust installation..."
            if curl -s --max-time 10 "$STEP_CA_URL/health" > /dev/null 2>&1; then
                log "Trust verification successful - can connect to step-ca without -k flag"
                return 0
            else
                log "WARNING: Trust verification failed - SSL connection still requires -k flag"
                return 1
            fi
        else
            log "ERROR: Downloaded file is not a valid certificate"
            rm -f "$temp_cert"
            return 1
        fi
    else
        log "ERROR: Failed to download root certificate from step-ca API"
        return 1
    fi
}

# Execute bootstrap if script is called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    bootstrap_step_ca
fi