#!/bin/bash

# Host Trust Certificate Installation Script
# Automatically installs step-ca intermediate certificate to host system

set -e

# Configuration
# Note: STEP_CA_CONTAINER_NAME is optional - if not set, auto-discovery will be used

# Get Docker context for certificate naming
get_docker_context() {
    local context_name
    if command -v docker >/dev/null 2>&1; then
        context_name=$(docker context show 2>/dev/null || echo "default")
    else
        context_name="default"
    fi
    echo "$context_name"
}

# Generate user-context-specific certificate name
DOCKER_CONTEXT=$(get_docker_context)
CERT_USER="${CERT_USER:-$(whoami)}"
CERT_NAME="step-ca-intermediate-${CERT_USER}-${DOCKER_CONTEXT}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] HOST-TRUST:${NC} $1"
}

log_success() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] HOST-TRUST:${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] HOST-TRUST:${NC} $1"
}

log_error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] HOST-TRUST:${NC} $1"
}

# Detect host OS
detect_host_os() {
    log "Detecting host operating system..." >&2
    
    if [ -f /etc/os-release ]; then
        local os_info=$(cat /etc/os-release)
        
        if echo "$os_info" | grep -qi "ubuntu"; then
            echo "ubuntu"
            return 0
        elif echo "$os_info" | grep -qi "debian"; then
            echo "debian"
            return 0
        elif echo "$os_info" | grep -qi "centos\|rhel\|red hat"; then
            echo "rhel"
            return 0
        elif echo "$os_info" | grep -qi "fedora"; then
            echo "fedora"
            return 0
        elif echo "$os_info" | grep -qi "arch"; then
            echo "arch"
            return 0
        elif echo "$os_info" | grep -qi "opensuse\|suse"; then
            echo "opensuse"
            return 0
        fi
    fi
    
    # Fallback: try to detect by package managers
    if command -v apt-get >/dev/null 2>&1; then
        echo "debian"
        return 0
    elif command -v yum >/dev/null 2>&1; then
        echo "rhel"
        return 0
    elif command -v dnf >/dev/null 2>&1; then
        echo "fedora"
        return 0
    elif command -v pacman >/dev/null 2>&1; then
        echo "arch"
        return 0
    elif command -v zypper >/dev/null 2>&1; then
        echo "opensuse"
        return 0
    fi
    
    log_error "Could not detect host operating system" >&2
    echo "unknown"
    return 1
}

# Get certificate directory for host OS
get_host_cert_directory() {
    local os_type="$1"
    
    case "$os_type" in
        "ubuntu"|"debian")
            echo "/usr/local/share/ca-certificates"
            ;;
        "rhel"|"centos"|"fedora")
            echo "/etc/pki/ca-trust/source/anchors"
            ;;
        "arch")
            echo "/etc/ca-certificates/trust-source/anchors"
            ;;
        "opensuse")
            echo "/etc/pki/trust/anchors"
            ;;
        *)
            echo ""
            return 1
            ;;
    esac
}

# Get trust update command for host OS
get_host_trust_update_command() {
    local os_type="$1"
    
    case "$os_type" in
        "ubuntu"|"debian")
            echo "update-ca-certificates"
            ;;
        "rhel"|"centos"|"fedora")
            echo "update-ca-trust"
            ;;
        "arch")
            echo "trust extract-compat"
            ;;
        "opensuse")
            echo "update-ca-certificates"
            ;;
        *)
            echo ""
            return 1
            ;;
    esac
}

# Check if running as root or with sudo
check_privileges() {
    log "Checking privileges..."
    
    if [ "$EUID" -eq 0 ]; then
        log_success "Running as root"
        return 0
    elif sudo -n /usr/bin/trust extract-compat 2>/dev/null; then
        log_success "Sudo access available for certificate management"
        return 0
    else
        log_error "This script requires root privileges or sudo access"
        log_error "Please run with: sudo $0"
        return 1
    fi
}

# Check if Docker is available
check_docker() {
    log "Checking Docker availability..."
    
    if ! command -v docker >/dev/null 2>&1; then
        log_error "Docker is not installed or not in PATH"
        return 1
    fi
    
    if ! docker info >/dev/null 2>&1; then
        log_error "Cannot connect to Docker daemon"
        log_error "Make sure Docker is running and you have access to it"
        return 1
    fi
    
    log_success "Docker is available"
    return 0
}

## Docker container discovery functions
labeled_cid() {
    docker ps --filter "label=$1" --format "{{.ID}}"
}

get_step_ca_container() {
    local step_ca_cid=""
    
    # Priority 1: Docker Labels
    local legacy_step_ca_cid; legacy_step_ca_cid="$(labeled_cid com.github.jrcs.letsencrypt_step_ca_companion.step_ca)"
    local new_step_ca_cid; new_step_ca_cid="$(labeled_cid com.smallstep.step-ca)"
    local generic_step_ca_cid; generic_step_ca_cid="$(labeled_cid com.github.step-ca.step-ca)"
    step_ca_cid="${new_step_ca_cid:-${generic_step_ca_cid:-$legacy_step_ca_cid}}"

    # Priority 2: Environment variable (with existence check)
    if [[ -z "${step_ca_cid}" && -n "${STEP_CA_CONTAINER_NAME:-}" ]]; then
        step_ca_cid="$(docker ps --filter "name=^${STEP_CA_CONTAINER_NAME}$" --format "{{.ID}}" | head -n1)"
        if [[ -z "$step_ca_cid" ]]; then
            echo "WARNING: Container '$STEP_CA_CONTAINER_NAME' not found, trying auto-detection" >&2
        fi
    fi
    
    # Priority 3: Auto-detection - search for containers ending EXACTLY with step-ca
    if [[ -z "$step_ca_cid" ]]; then
        # Method 1: Search by step-ca environment variables AND name ending EXACTLY with step-ca
        step_ca_cid="$(docker ps --format "{{.ID}} {{.Names}}" | grep -E 'step-ca$' | head -n1 | cut -d' ' -f1)"
        
        # Verify it has step-ca environment variables
        if [[ -n "$step_ca_cid" ]]; then
            if ! docker inspect "$step_ca_cid" --format '{{range .Config.Env}}{{.}}{{"\n"}}{{end}}' | grep -q "DOCKER_STEPCA_"; then
                step_ca_cid=""
            fi
        fi
        
        # Method 2: Search by port 9000 AND name ending EXACTLY with step-ca
        if [[ -z "$step_ca_cid" ]]; then
            step_ca_cid="$(docker ps --format "{{.ID}} {{.Names}} {{.Ports}}" | grep -E 'step-ca.*:9000->' | head -n1 | cut -d' ' -f1)"
        fi
        
        # Method 3: Search only by container name ending EXACTLY with step-ca
        if [[ -z "$step_ca_cid" ]]; then
            step_ca_cid="$(docker ps --format "{{.ID}} {{.Names}}" | grep -E 'step-ca$' | head -n1 | cut -d' ' -f1)"
        fi
    fi

    # Return container ID if found
    [[ -n "$step_ca_cid" ]] && echo "$step_ca_cid"
}

# Check if step-ca container is running
check_step_ca_container() {
    log "Discovering step-ca container..."
    
    local step_ca_container_id; step_ca_container_id=$(get_step_ca_container)
    
    if [[ -z "$step_ca_container_id" ]]; then
        log_error "Could not find step-ca container"
        log_error "Tried methods: labels, environment variable, auto-detection"
        return 1
    fi
    
    # Get container name for logging
    local container_name; container_name=$(docker inspect "$step_ca_container_id" --format '{{.Name}}' | sed 's/^\///')
    log_success "Found step-ca container: $container_name (ID: $step_ca_container_id)"
    
    # Update global variable for use in other functions
    STEP_CA_CONTAINER_NAME="$container_name"
    
    if [[ $(docker inspect "$step_ca_container_id" --format '{{.State.Status}}') != "running" ]]; then
        log_error "step-ca container '$container_name' is not running"
        return 1
    fi
    
    log_success "step-ca container is running"
    return 0
}

# Wait for step-ca to be fully ready
wait_for_step_ca_ready() {
    local max_attempts=30
    local attempt=1
    
    log "Waiting for step-ca to be fully ready..."
    
    while [ $attempt -le $max_attempts ]; do
        # Check if step-ca health endpoint is responding
        if docker exec "$STEP_CA_CONTAINER_NAME" curl -k -s --max-time 3 "https://localhost:9000/health" >/dev/null 2>&1; then
            log_success "step-ca is ready (attempt $attempt/$max_attempts)"
            return 0
        fi
        
        log "step-ca not ready yet, waiting... (attempt $attempt/$max_attempts)"
        sleep 2
        attempt=$((attempt + 1))
    done
    
    log_warning "step-ca did not become ready within timeout, proceeding anyway"
    return 1
}

# Get step-ca intermediate certificate
get_step_ca_certificate() {
    local cert_file="$1"
    
    log "Retrieving step-ca intermediate certificate..."
    
    # Wait for step-ca to be ready first
    wait_for_step_ca_ready
    
    # Try to get certificate from step-ca container
    if docker exec "$STEP_CA_CONTAINER_NAME" cat /home/step/certs/intermediate_ca.crt > "$cert_file" 2>/dev/null; then
        if grep -q "BEGIN CERTIFICATE" "$cert_file"; then
            log_success "Successfully retrieved step-ca certificate"
            return 0
        else
            log_error "Invalid certificate format"
            return 1
        fi
    else
        log_error "Failed to retrieve certificate from step-ca container"
        return 1
    fi
}

# Install certificate to host system
install_certificate_to_host() {
    local cert_file="$1"
    local os_type="$2"
    
    local cert_dir=$(get_host_cert_directory "$os_type")
    local update_cmd=$(get_host_trust_update_command "$os_type")
    
    if [ -z "$cert_dir" ] || [ -z "$update_cmd" ]; then
        log_error "Unsupported operating system: $os_type"
        return 1
    fi
    
    log "Installing certificate to host system..."
    log "OS: $os_type"
    log "Certificate directory: $cert_dir"
    log "Update command: $update_cmd"
    
    # Create certificate directory if it doesn't exist
    if [ "$EUID" -eq 0 ]; then
        mkdir -p "$cert_dir"
    else
        sudo mkdir -p "$cert_dir"
    fi
    
    # Copy certificate to system directory
    local dest_file="$cert_dir/${CERT_NAME}.crt"
    if [ "$EUID" -eq 0 ]; then
        cp "$cert_file" "$dest_file"
        chmod 644 "$dest_file"
    else
        sudo cp "$cert_file" "$dest_file"
        sudo chmod 644 "$dest_file"
    fi
    
    log_success "Certificate copied to: $dest_file"
    
    # Update trust store
    log "Updating system trust store..."
    if [ "$EUID" -eq 0 ]; then
        $update_cmd
    else
        sudo $update_cmd
    fi
    
    log_success "Trust store updated successfully"
    return 0
}

# Verify trust installation
verify_installation() {
    log "Verifying trust installation..."
    
    # Try to make a simple HTTPS request to step-ca
    if command -v curl >/dev/null 2>&1; then
        # Get step-ca container IP or use container name if in same network
        local step_ca_url="https://${STEP_CA_CONTAINER_NAME}:9000/health"
        
        # Try direct connection first
        if curl -s --max-time 5 "$step_ca_url" >/dev/null 2>&1; then
            log_success "Trust verification successful - can connect to step-ca via HTTPS"
            return 0
        else
            log_warning "Direct HTTPS connection to step-ca failed"
            log_warning "This might be normal if step-ca is not accessible from host network"
        fi
    else
        log_warning "curl not available for verification"
    fi
    
    # Check if certificate exists in system store
    local os_type=$(detect_host_os)
    local cert_dir=$(get_host_cert_directory "$os_type")
    local cert_file="$cert_dir/${CERT_NAME}.crt"
    
    if [ -f "$cert_file" ]; then
        log_success "Certificate found in system trust store: $cert_file"
        return 0
    else
        log_error "Certificate not found in system trust store"
        return 1
    fi
}

# Main installation function
main() {
    log "Starting step-ca host trust certificate installation..."
    log "User: $CERT_USER"
    log "Docker context: $DOCKER_CONTEXT"
    log "Certificate name: $CERT_NAME"
    log "Step-CA container: $STEP_CA_CONTAINER_NAME"
    
    # Check requirements
    if ! check_privileges; then
        exit 1
    fi
    
    if ! check_docker; then
        exit 1
    fi
    
    if ! check_step_ca_container; then
        exit 1
    fi
    
    # Detect host OS
    local os_type=$(detect_host_os)
    if [ "$os_type" = "unknown" ]; then
        log_error "Unsupported operating system"
        log_error "Supported: Ubuntu, Debian, CentOS, RHEL, Fedora, Arch Linux, openSUSE"
        exit 1
    fi
    
    log_success "Detected OS: $os_type"
    
    # Create temporary file for certificate
    local temp_cert=$(mktemp)
    trap "rm -f $temp_cert" EXIT
    
    # Get certificate from step-ca
    if ! get_step_ca_certificate "$temp_cert"; then
        exit 1
    fi
    
    # Install certificate to host
    if ! install_certificate_to_host "$temp_cert" "$os_type"; then
        exit 1
    fi
    
    # Verify installation
    verify_installation
    
    log_success "step-ca trust certificate installation completed successfully!"
    log "You can now make HTTPS requests to step-ca signed certificates without SSL errors"
}

# Show usage information
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Install step-ca intermediate certificate to host system trust store"
    echo "Supports multiple Docker contexts and users - certificates are named by user and context"
    echo ""
    echo "Environment Variables:"
    echo "  STEP_CA_CONTAINER_NAME    Name of step-ca container (optional, auto-detected)"
    echo "  CERT_USER                 User name for certificate naming (optional, defaults to current user)"
    echo ""
    echo "Examples:"
    echo "  $0                                          # Use current user and Docker context"
    echo "  CERT_USER=admin $0                         # Use specific user name"
    echo "  STEP_CA_CONTAINER_NAME=my-ca $0            # Use custom container name"
    echo "  docker context use production && $0        # Install for production context"
    echo ""
    echo "Multi-User Docker Context Support:"
    echo "  - Certificates are named: step-ca-intermediate-<user>-<context>"
    echo "  - Multiple users and contexts can coexist without conflicts"
    echo "  - Switching contexts triggers automatic certificate updates (with systemd)"
    echo "  - Examples: step-ca-intermediate-salazar-manjaro.crt, step-ca-intermediate-admin-production.crt"
    echo ""
    echo "Supported Operating Systems:"
    echo "  - Ubuntu/Debian"
    echo "  - CentOS/RHEL/Fedora"
    echo "  - Arch Linux"
    echo "  - openSUSE"
}

# Handle command line arguments
case "${1:-}" in
    -h|--help)
        show_usage
        exit 0
        ;;
    *)
        main "$@"
        ;;
esac