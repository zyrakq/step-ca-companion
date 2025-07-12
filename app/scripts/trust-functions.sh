#!/bin/bash

# Trust certificate installation functions for step-ca-companion

# Import required functions
source /app/scripts/docker-api-functions.sh
source /app/scripts/os-detection.sh

# Set Docker socket path
export DOCKER_HOST=unix:///var/run/docker.sock

log_trust() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] TRUST-FUNCTIONS: $1"
}

# Check if step-ca is available
check_step_ca_availability() {
    log_trust "Checking step-ca availability..."
    
    # First, try to find step-ca container
    local _step_ca_container; _step_ca_container=$(get_step_ca_container)
    if [[ -z "$_step_ca_container" ]]; then
        log_trust "WARNING: Could not find step-ca container"
        return 1
    else
        log_trust "Found step-ca container: $_step_ca_container"
        # Update URLs to use discovered container
        local container_name; container_name=$(get_container_name "$_step_ca_container")
        STEP_CA_URL="https://${container_name}:9000"
        log_trust "Updated step-ca URL to: $STEP_CA_URL"
    fi
    
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        # Check health endpoint
        if curl -k -s --max-time 5 "$STEP_CA_URL/health" > /dev/null 2>&1; then
            log_trust "step-ca is available (attempt $attempt/$max_attempts)"
            return 0
        else
            log_trust "step-ca health endpoint not ready (attempt $attempt/$max_attempts)"
        fi
        
        if [ $attempt -lt $max_attempts ]; then
            sleep 5
            attempt=$((attempt + 1))
        else
            break
        fi
    done
    
    log_trust "step-ca is unavailable after $max_attempts attempts"
    return 1
}

# Check if container is running (use function from os-detection.sh)
# is_container_running() is already defined in os-detection.sh

# Get step-ca intermediate certificate
get_step_ca_certificate() {
    local cert_file="$1"
    
    log_trust "Retrieving step-ca intermediate certificate..."
    
    # Get step-ca container
    local step_ca_container_id; step_ca_container_id=$(get_step_ca_container)
    
    if [[ -z "$step_ca_container_id" ]]; then
        log_trust "ERROR: Could not find step-ca container"
        return 1
    fi
    
    # Try to get certificate from step-ca container (simple approach like in original)
    if docker exec "$step_ca_container_id" cat /home/step/certs/intermediate_ca.crt > "$cert_file" 2>/dev/null; then
        if grep -q "BEGIN CERTIFICATE" "$cert_file"; then
            log_trust "Successfully retrieved step-ca certificate"
            return 0
        else
            log_trust "ERROR: Invalid certificate format"
            return 1
        fi
    else
        log_trust "ERROR: Failed to retrieve certificate from step-ca container"
        return 1
    fi
}

# Install required packages in container
install_ca_packages() {
    local container_id="$1"
    local os_type="$2"
    
    log_trust "Installing CA packages for $os_type in container $container_id"
    
    local install_cmd=$(get_install_command "$os_type" "ca-certificates")
    
    if [ -z "$install_cmd" ]; then
        log_trust "ERROR: Unknown OS type: $os_type"
        return 1
    fi
    
    log_trust "Running: $install_cmd"
    
    if docker exec --user root "$container_id" sh -c "$install_cmd" >/dev/null 2>&1; then
        log_trust "Successfully installed ca-certificates package"
        return 0
    else
        log_trust "WARNING: Failed to install ca-certificates package (may already be installed)"
        # Continue anyway, package might already be installed
        return 0
    fi
}

# Copy certificate to container
copy_certificate_to_container() {
    local container_id="$1"
    local cert_file="$2"
    local os_type="$3"
    
    local cert_dir=$(get_cert_directory "$os_type")
    
    if [ -z "$cert_dir" ]; then
        log_trust "ERROR: Unknown certificate directory for OS: $os_type"
        return 1
    fi
    
    log_trust "Copying certificate to $cert_dir in container $container_id"
    
    # Create certificate directory in container
    if ! docker exec --user root "$container_id" mkdir -p "$cert_dir" 2>/dev/null; then
        log_trust "ERROR: Failed to create certificate directory"
        return 1
    fi
    
    # Copy certificate to container
    if docker cp "$cert_file" "$container_id:$cert_dir/step-ca-intermediate.crt"; then
        log_trust "Successfully copied certificate to container"
        return 0
    else
        log_trust "ERROR: Failed to copy certificate to container"
        return 1
    fi
}

# Update trust store in container
update_trust_store() {
    local container_id="$1"
    local os_type="$2"
    
    local update_cmd=$(get_trust_update_command "$os_type")
    
    if [ -z "$update_cmd" ]; then
        log_trust "ERROR: Unknown trust update command for OS: $os_type"
        return 1
    fi
    
    log_trust "Updating trust store with command: $update_cmd"
    
    if docker exec --user root "$container_id" sh -c "$update_cmd" >/dev/null 2>&1; then
        log_trust "Successfully updated trust store"
        return 0
    else
        log_trust "ERROR: Failed to update trust store"
        return 1
    fi
}

# Wait for container to be fully ready
wait_for_container_ready_trust() {
    local container_id="$1"
    local container_name="$2"
    
    log_trust "Waiting for container $container_name to be fully ready..."
    
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        # Try to execute a simple command to check if container is responsive
        if docker exec "$container_id" sh -c "echo 'ready'" >/dev/null 2>&1; then
            log_trust "Container $container_name is ready"
            return 0
        fi
        
        log_trust "Container $container_name not ready yet, waiting... (attempt $attempt/$max_attempts)"
        sleep 2
        attempt=$((attempt + 1))
    done
    
    log_trust "ERROR: Container $container_name did not become ready within timeout"
    return 1
}

# Main function to install trust certificate in container
install_trust_certificate() {
    local container_id="$1"
    local container_name="$2"
    
    log_trust "Installing trust certificate for container: $container_name ($container_id)"
    
    # Check if container is running
    if ! is_container_running "$container_id"; then
        log_trust "WARNING: Container $container_name is not running, skipping"
        return 1
    fi
    
    # Wait for container to be fully ready
    if ! wait_for_container_ready_trust "$container_id" "$container_name"; then
        log_trust "ERROR: Container $container_name is not ready, skipping trust installation"
        return 1
    fi
    
    # Detect OS
    local os_type=$(detect_container_os "$container_id")
    if [ "$os_type" = "unknown" ]; then
        log_trust "ERROR: Could not detect OS for container $container_name"
        return 1
    fi
    
    log_trust "Detected OS: $os_type for container $container_name"
    
    # Get step-ca certificate
    local temp_cert="/tmp/step-ca-intermediate-$container_id.crt"
    if ! get_step_ca_certificate "$temp_cert"; then
        log_trust "ERROR: Failed to get step-ca certificate"
        return 1
    fi
    
    # Install CA packages
    if ! install_ca_packages "$container_id" "$os_type"; then
        log_trust "WARNING: Package installation failed, continuing anyway"
    fi
    
    # Copy certificate to container
    if ! copy_certificate_to_container "$container_id" "$temp_cert" "$os_type"; then
        rm -f "$temp_cert"
        return 1
    fi
    
    # Update trust store
    if ! update_trust_store "$container_id" "$os_type"; then
        rm -f "$temp_cert"
        return 1
    fi
    
    # Cleanup
    rm -f "$temp_cert"
    
    log_trust "Successfully installed trust certificate for container $container_name"
    return 0
}

# Verify trust installation
verify_trust_installation() {
    local container_id="$1"
    local container_name="$2"
    
    log_trust "Verifying trust installation for container: $container_name"
    
    # Get step-ca container name for verification
    local step_ca_container_id; step_ca_container_id=$(get_step_ca_container)
    local step_ca_container_name=""
    
    if [[ -n "$step_ca_container_id" ]]; then
        step_ca_container_name=$(get_container_name "$step_ca_container_id")
    else
        step_ca_container_name="step-ca"  # fallback
    fi
    
    # Try to make a simple HTTPS request to step-ca
    if docker exec "$container_id" sh -c "command -v curl >/dev/null 2>&1" 2>/dev/null; then
        if docker exec "$container_id" curl -s --max-time 5 "https://${step_ca_container_name}:9000/health" >/dev/null 2>&1; then
            log_trust "Trust verification successful for container $container_name"
            return 0
        else
            log_trust "WARNING: Trust verification failed for container $container_name (curl test failed)"
            return 1
        fi
    else
        log_trust "INFO: Cannot verify trust (curl not available in container $container_name)"
        return 0
    fi
}

# Process trust installation for containers with STEP_CA_TRUST=true
process_trust_containers() {
    log_trust "Processing trust certificate installation for containers..."
    
    # Get all running containers with STEP_CA_TRUST environment variable
    docker ps --format "{{.ID}}\t{{.Names}}" | while IFS=$'\t' read -r container_id container_name; do
        # Skip empty lines
        [[ -z "$container_id" ]] && continue
        
        # Check if container has STEP_CA_TRUST=true
        if docker inspect "$container_id" --format='{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep -q "^STEP_CA_TRUST=true$"; then
            log_trust "Found container with STEP_CA_TRUST=true: $container_name ($container_id)"
            install_trust_certificate "$container_id" "$container_name"
        fi
    done
}