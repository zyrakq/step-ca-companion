#!/bin/bash

# User Systemd Integration Installation Script
# Automatically monitors step-ca container for current user and updates host trust certificate

set -e

# Configuration
CURRENT_USER=$(whoami)
USER_HOME="/home/$CURRENT_USER"
USER_ID=$(id -u "$CURRENT_USER")

# User directories
USER_SYSTEMD_DIR="$USER_HOME/.config/systemd/user"
USER_BIN_DIR="$USER_HOME/.local/bin"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] USER-SYSTEMD:${NC} $1"
}

log_success() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] USER-SYSTEMD:${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] USER-SYSTEMD:${NC} $1"
}

log_error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] USER-SYSTEMD:${NC} $1"
}

# Detect distribution
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    elif [ -f /etc/debian_version ]; then
        echo "debian"
    elif [ -f /etc/arch-release ]; then
        echo "arch"
    else
        echo "unknown"
    fi
}

# Check if user systemd is supported
check_user_systemd_support() {
    log "Checking user systemd support..."
    
    if ! command -v systemctl >/dev/null 2>&1; then
        log_error "systemctl not found - systemd is not available"
        return 1
    fi
    
    # Check if systemd --user is available
    if ! systemctl --user --version >/dev/null 2>&1; then
        log_error "systemd --user is not available"
        return 1
    fi
    
    log_success "User systemd is available"
    return 0
}

# Check distribution-specific requirements
check_distro_requirements() {
    local distro="$1"
    
    log "Checking requirements for $distro..."
    
    case "$distro" in
        "ubuntu"|"debian")
            # Check for dbus-user-session
            if ! dpkg -l | grep -q dbus-user-session 2>/dev/null; then
                log_warning "dbus-user-session not installed"
                log "Installing dbus-user-session..."
                if ! sudo apt-get update && sudo apt-get install -y dbus-user-session; then
                    log_error "Failed to install dbus-user-session"
                    return 1
                fi
                log_success "dbus-user-session installed"
            fi
            ;;
        "arch")
            # Usually works out of the box
            log_success "Arch Linux systemd --user support detected"
            ;;
        "fedora"|"rhel"|"centos")
            # Usually works out of the box
            log_success "Fedora/RHEL systemd --user support detected"
            ;;
        *)
            log_warning "Unknown distribution, proceeding with basic checks"
            ;;
    esac
    
    return 0
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

# Check if install-host-trust.sh exists
check_trust_script() {
    local script_dir=$(dirname "$(realpath "$0")")
    local trust_script="$script_dir/install-host-trust.sh"
    
    log "Checking for install-host-trust.sh script..." >&2
    
    if [ ! -f "$trust_script" ]; then
        log_error "install-host-trust.sh not found at: $trust_script" >&2
        log_error "Make sure both scripts are in the same directory" >&2
        return 1
    fi
    
    if [ ! -x "$trust_script" ]; then
        log_error "install-host-trust.sh is not executable" >&2
        log_error "Run: chmod +x $trust_script" >&2
        return 1
    fi
    
    log_success "install-host-trust.sh found and executable" >&2
    echo "$trust_script"
    return 0
}

# Setup certificate management group and permissions
setup_cert_group() {
    log "Setting up certificate management group..."
    
    local group_name="step-ca-certs"
    local distro="$1"
    
    # Create group if it doesn't exist
    if ! getent group "$group_name" >/dev/null 2>&1; then
        log "Creating group: $group_name"
        sudo groupadd "$group_name"
        log_success "Group $group_name created"
    else
        log "Group $group_name already exists"
    fi
    
    # Add current user to the group
    if ! groups "$CURRENT_USER" | grep -q "$group_name"; then
        log "Adding user $CURRENT_USER to group $group_name"
        sudo usermod -a -G "$group_name" "$CURRENT_USER"
        log_success "User $CURRENT_USER added to group $group_name"
    else
        log "User $CURRENT_USER is already in group $group_name"
    fi
    
    # Setup directory permissions and sudoers rules based on distribution
    local cert_dir=""
    local update_cmd=""
    case "$distro" in
        "ubuntu"|"debian")
            cert_dir="/usr/local/share/ca-certificates"
            update_cmd="/usr/sbin/update-ca-certificates"
            ;;
        "arch")
            cert_dir="/etc/ca-certificates/trust-source/anchors"
            update_cmd="/usr/bin/trust extract-compat"
            ;;
        "fedora"|"rhel"|"centos")
            cert_dir="/etc/pki/ca-trust/source/anchors"
            update_cmd="/usr/bin/update-ca-trust"
            ;;
        "opensuse")
            cert_dir="/etc/pki/trust/anchors"
            update_cmd="/usr/sbin/update-ca-certificates"
            ;;
        *)
            log_error "Unsupported distribution for group setup: $distro"
            return 1
            ;;
    esac
    
    # Create certificate directory if it doesn't exist
    sudo mkdir -p "$cert_dir"
    
    # Set group ownership and permissions on certificate directory
    log "Setting up permissions for certificate directory: $cert_dir"
    sudo chgrp "$group_name" "$cert_dir"
    sudo chmod g+w "$cert_dir"
    
    # Create sudoers rule for the group
    local sudoers_file="/etc/sudoers.d/step-ca-certs"
    log "Creating sudoers rule for group: $sudoers_file"
    
    cat << EOF | sudo tee "$sudoers_file" >/dev/null
# Allow step-ca-certs group to update certificates without password
%$group_name ALL=(root) NOPASSWD: /usr/bin/mkdir -p $cert_dir, \\
                                   /usr/bin/cp * $cert_dir/*, \\
                                   /usr/bin/chmod 644 $cert_dir/*, \\
                                   $update_cmd
EOF
    
    # Set proper permissions on sudoers file
    sudo chmod 440 "$sudoers_file"
    
    # Validate sudoers file
    if sudo visudo -c -f "$sudoers_file"; then
        log_success "Sudoers rule for group created successfully"
        
        # Restart user systemd manager to pick up new group membership
        log "Restarting user systemd manager to apply group membership..."
        systemctl --user daemon-reexec
        
        log_success "Group permissions configured - service will have access to certificate commands"
        return 0
    else
        log_error "Invalid sudoers rule, removing..."
        sudo rm -f "$sudoers_file"
        return 1
    fi
}

# Remove certificate management group and permissions
remove_cert_group() {
    log "Removing certificate management group setup..."
    
    local group_name="step-ca-certs"
    local sudoers_file="/etc/sudoers.d/step-ca-certs"
    
    # Remove sudoers rule
    if [ -f "$sudoers_file" ]; then
        sudo rm -f "$sudoers_file"
        log_success "Sudoers rule removed"
    fi
    
    # Remove user from group
    if groups "$CURRENT_USER" | grep -q "$group_name"; then
        log "Removing user $CURRENT_USER from group $group_name"
        sudo gpasswd -d "$CURRENT_USER" "$group_name"
        log_success "User removed from group"
    fi
    
    # Note: We don't remove the group itself as other users might be using it
    log_warning "Group $group_name not removed (may be used by other users)"
}


# Create user directories
create_user_directories() {
    log "Creating user directories..."
    
    # Create systemd user directory
    if [ ! -d "$USER_SYSTEMD_DIR" ]; then
        mkdir -p "$USER_SYSTEMD_DIR"
        log_success "Created: $USER_SYSTEMD_DIR"
    fi
    
    # Create user bin directory
    if [ ! -d "$USER_BIN_DIR" ]; then
        mkdir -p "$USER_BIN_DIR"
        log_success "Created: $USER_BIN_DIR"
    fi
    
    return 0
}

# Install user systemd integration
install_user_systemd_integration() {
    local trust_script="$1"
    
    log "Installing user systemd integration for automatic certificate updates..."
    log "User: $CURRENT_USER"
    log "Step-CA container: ${STEP_CA_CONTAINER_NAME:-auto-detect}"
    
    local monitor_script="$USER_BIN_DIR/step-ca-user-monitor.sh"
    local host_trust_script="$USER_BIN_DIR/install-host-trust.sh"
    
    # Copy trust script to user directory
    log "Copying trust script to user directory: $host_trust_script"
    cp "$trust_script" "$host_trust_script"
    chmod +x "$host_trust_script"
    
    # Create user Docker events monitor script
    log "Creating user Docker events monitor script: $monitor_script"
    
    local monitor_content="#!/bin/bash

# Monitor step-ca container events and update host trust certificate for current user
# Note: STEP_CA_CONTAINER_NAME is optional - if not set, auto-discovery will be used
STEP_CA_CONTAINER_NAME=\${STEP_CA_CONTAINER_NAME:-\"\"}

# Current user context
CURRENT_USER=\"$CURRENT_USER\"
USER_HOME=\"$USER_HOME\"

log_monitor() {
    echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] USER-MONITOR: \$1\"
}

# Extract Docker context from user config file
get_current_docker_context() {
    local config_file=\"\$USER_HOME/.docker/config.json\"
    local context_name=\"default\"
    
    if [[ -f \"\$config_file\" ]]; then
        # Try with jq if available
        if command -v jq >/dev/null 2>&1; then
            local user_context=\$(jq -r '.currentContext // \"default\"' \"\$config_file\" 2>/dev/null)
            if [[ -n \"\$user_context\" && \"\$user_context\" != \"null\" ]]; then
                context_name=\"\$user_context\"
            fi
        else
            # Fallback: simple grep for currentContext
            local user_context=\$(grep -o '\"currentContext\"[[:space:]]*:[[:space:]]*\"[^\"]*\"' \"\$config_file\" 2>/dev/null | sed 's/.*\"\\([^\"]*\\)\"/\\1/')
            if [[ -n \"\$user_context\" ]]; then
                context_name=\"\$user_context\"
            fi
        fi
    fi
    
    echo \"\$context_name\"
}

# Monitor Docker context changes
monitor_context_changes() {
    local config_file=\"\$USER_HOME/.docker/config.json\"
    local last_context=\"\$(get_current_docker_context)\"
    
    log_monitor \"Starting context monitoring for user \$CURRENT_USER\"
    log_monitor \"Initial context: \$last_context\"
    
    # Monitor config file changes with inotify if available
    if command -v inotifywait >/dev/null 2>&1; then
        log_monitor \"Using inotify for real-time config monitoring\"
        inotifywait -m -e modify \"\$config_file\" 2>/dev/null | while read path action file; do
            local current_context=\"\$(get_current_docker_context)\"
            if [[ \"\$current_context\" != \"\$last_context\" ]]; then
                log_monitor \"Context changed: \$last_context -> \$current_context\"
                last_context=\"\$current_context\"
                
                # Check for step-ca in new context and update certificate
                check_and_update_certificate \"\$current_context\"
            fi
        done &
    else
        log_monitor \"inotifywait not available, using periodic checking\"
        # Fallback: periodic checking
        while true; do
            sleep 10
            local current_context=\"\$(get_current_docker_context)\"
            if [[ \"\$current_context\" != \"\$last_context\" ]]; then
                log_monitor \"Context changed: \$last_context -> \$current_context\"
                last_context=\"\$current_context\"
                check_and_update_certificate \"\$current_context\"
            fi
        done &
    fi
}

# Check for step-ca and update certificate
check_and_update_certificate() {
    local context=\"\$1\"
    
    log_monitor \"Checking step-ca in context: \$context\"
    
    # Set Docker context
    local old_docker_context=\"\$DOCKER_CONTEXT\"
    export DOCKER_CONTEXT=\"\$context\"
    
    # Debug: show Docker host being used
    local docker_host=\"\$DOCKER_HOST\"
    if [[ -n \"\$DOCKER_CONTEXT\" && \"\$DOCKER_CONTEXT\" != \"default\" ]]; then
        local context_file=\"\$USER_HOME/.docker/contexts/meta/\$(echo -n \"\$DOCKER_CONTEXT\" | sha256sum | cut -d' ' -f1)/meta.json\"
        if [[ -f \"\$context_file\" ]] && command -v jq >/dev/null 2>&1; then
            docker_host=\$(jq -r '.Endpoints.docker.Host // empty' \"\$context_file\" 2>/dev/null)
        fi
        if [[ -z \"\$docker_host\" ]]; then
            docker_host=\$(docker context inspect \"\$DOCKER_CONTEXT\" --format '{{.Endpoints.docker.Host}}' 2>/dev/null || echo \"\")
        fi
    fi
    if [[ -z \"\$docker_host\" ]]; then
        docker_host=\"unix:///var/run/docker.sock\"
    fi
    log_monitor \"Using Docker host: \$docker_host for context: \$context\"
    
    # Find step-ca container
    local container_id=\$(get_step_ca_container)
    
    if [[ -n \"\$container_id\" ]]; then
        log_monitor \"Found step-ca container in context \$context: \$container_id\"
        update_certificate \"\$context\"
    else
        log_monitor \"No step-ca container found in context \$context\"
    fi
    
    # Restore original Docker context
    export DOCKER_CONTEXT=\"\$old_docker_context\"
}

# Update certificate for current user and context
update_certificate() {
    local context=\"\$1\"
    
    log_monitor \"Updating certificate for user \$CURRENT_USER in context \$context\"
    
    # Call install-host-trust.sh with environment variables
    DOCKER_CONTEXT=\"\$context\" CERT_USER=\"\$CURRENT_USER\" \"\$USER_HOME/.local/bin/install-host-trust.sh\"
}

## Docker container discovery functions
labeled_cid() {
    docker ps --filter \"label=\$1\" --format \"{{.ID}}\"
}

get_step_ca_container() {
    local step_ca_cid=\"\"
    
    # Priority 1: Docker Labels
    local legacy_step_ca_cid; legacy_step_ca_cid=\"\$(labeled_cid com.github.jrcs.letsencrypt_step_ca_companion.step_ca)\"
    local new_step_ca_cid; new_step_ca_cid=\"\$(labeled_cid com.smallstep.step-ca)\"
    local generic_step_ca_cid; generic_step_ca_cid=\"\$(labeled_cid com.github.step-ca.step-ca)\"
    step_ca_cid=\"\${new_step_ca_cid:-\${generic_step_ca_cid:-\$legacy_step_ca_cid}}\"

    # Priority 2: Environment variable (with existence check)
    if [[ -z \"\${step_ca_cid}\" && -n \"\${STEP_CA_CONTAINER_NAME:-}\" ]]; then
        step_ca_cid=\"\$(docker ps --filter \"name=^\$STEP_CA_CONTAINER_NAME\$\" --format \"{{.ID}}\" | head -n1)\"
        if [[ -z \"\$step_ca_cid\" ]]; then
            echo \"WARNING: Container '\$STEP_CA_CONTAINER_NAME' not found, trying auto-detection\" >&2
        fi
    fi
    
    # Priority 3: Auto-detection - search for containers ending EXACTLY with step-ca
    if [[ -z \"\$step_ca_cid\" ]]; then
        # Method 1: Search by step-ca environment variables AND name ending EXACTLY with step-ca
        step_ca_cid=\"\$(docker ps --format \"{{.ID}} {{.Names}}\" | grep -E 'step-ca\$' | head -n1 | cut -d' ' -f1)\"
        
        # Verify it has step-ca environment variables
        if [[ -n \"\$step_ca_cid\" ]]; then
            if ! docker inspect \"\$step_ca_cid\" --format '{{range .Config.Env}}{{.}}{{\"\n\"}}{{end}}' | grep -q \"DOCKER_STEPCA_\"; then
                step_ca_cid=\"\"
            fi
        fi
        
        # Method 2: Search by port 9000 AND name ending EXACTLY with step-ca
        if [[ -z \"\$step_ca_cid\" ]]; then
            step_ca_cid=\"\$(docker ps --format \"{{.ID}} {{.Names}} {{.Ports}}\" | grep -E 'step-ca.*:9000->' | head -n1 | cut -d' ' -f1)\"
        fi
        
        # Method 3: Search only by container name ending EXACTLY with step-ca
        if [[ -z \"\$step_ca_cid\" ]]; then
            step_ca_cid=\"\$(docker ps --format \"{{.ID}} {{.Names}}\" | grep -E 'step-ca\$' | head -n1 | cut -d' ' -f1)\"
        fi
    fi

    # Return container ID if found
    [[ -n \"\$step_ca_cid\" ]] && echo \"\$step_ca_cid\"
}

# Wait for step-ca to be fully ready
wait_for_step_ca_ready() {
    local max_attempts=60
    local attempt=1
    local step_ca_container_id; step_ca_container_id=\$(get_step_ca_container)
    
    if [[ -z \"\$step_ca_container_id\" ]]; then
        log_monitor \"ERROR: Could not find step-ca container\"
        return 1
    fi
    
    log_monitor \"Waiting for step-ca to be fully ready...\"
    
    while [ \$attempt -le \$max_attempts ]; do
        # Check if step-ca health endpoint is responding
        if docker exec \"\$step_ca_container_id\" curl -k -s --max-time 3 \"https://localhost:9000/health\" >/dev/null 2>&1; then
            log_monitor \"step-ca is ready (attempt \$attempt/\$max_attempts)\"
            return 0
        fi
        
        log_monitor \"step-ca not ready yet, waiting... (attempt \$attempt/\$max_attempts)\"
        sleep 2
        attempt=\$((attempt + 1))
    done
    
    log_monitor \"WARNING: step-ca did not become ready within timeout, proceeding anyway\"
    return 1
}

log_monitor \"Starting Docker events monitor for step-ca containers (user: \$CURRENT_USER)...\"

# Initial check and certificate update
current_context=\"\$(get_current_docker_context)\"
log_monitor \"Initial context: \$current_context\"
check_and_update_certificate \"\$current_context\"

# Start context monitoring in background
monitor_context_changes &

# Start periodic container checking in background
periodic_container_check() {
    while true; do
        sleep 30
        local current_context=\"\$(get_current_docker_context)\"
        log_monitor \"Periodic check: Looking for step-ca in context \$current_context\"
        check_and_update_certificate \"\$current_context\"
    done
}
periodic_container_check &

# Monitor Docker events for step-ca container start events
docker events --filter event=start --format '{{.Actor.Attributes.name}} {{.Status}}' | while read container_name event; do
    if [ \"\$event\" = \"start\" ]; then
        log_monitor \"Container started: \$container_name\"
        
        # Check if this is a step-ca container in current context
        current_context=\"\$(get_current_docker_context)\"
        old_docker_context=\"\$DOCKER_CONTEXT\"
        export DOCKER_CONTEXT=\"\$current_context\"
        
        step_ca_container_id=\$(get_step_ca_container)
        if [[ -n \"\$step_ca_container_id\" ]]; then
            # Get container name to compare
            current_container_name=\$(docker inspect \"\$step_ca_container_id\" --format '{{.Name}}' | sed 's/^\///')
            
            if [[ \"\$current_container_name\" == \"\$container_name\" ]]; then
                log_monitor \"step-ca container \$container_name started in context \$current_context\"
                
                # Wait for readiness and update certificate
                if wait_for_step_ca_ready; then
                    log_monitor \"step-ca is ready, updating certificate\"
                    update_certificate \"\$current_context\"
                else
                    log_monitor \"step-ca readiness check failed, but attempting certificate update anyway\"
                    update_certificate \"\$current_context\"
                fi
            fi
        fi
        
        # Restore original context
        export DOCKER_CONTEXT=\"\$old_docker_context\"
    fi
done"

    # Create user systemd service
    log "Creating user systemd service..."
    
    local service_content="[Unit]
Description=Monitor step-ca container events for current user
After=docker.service
Wants=docker.service

[Service]
Type=simple
ExecStart=/usr/bin/sg step-ca-certs -c '$monitor_script'
Environment=HOME=$USER_HOME
Environment=USER=$CURRENT_USER
Environment=XDG_RUNTIME_DIR=/run/user/$USER_ID
Environment=STEP_CA_CONTAINER_NAME=${STEP_CA_CONTAINER_NAME:-}
Restart=always
RestartSec=10

[Install]
WantedBy=default.target"

    # Install files
    echo "$monitor_content" > "$monitor_script"
    chmod +x "$monitor_script"
    echo "$service_content" > "$USER_SYSTEMD_DIR/step-ca-monitor.service"
    
    # Reload user systemd and enable service
    systemctl --user daemon-reload
    systemctl --user enable step-ca-monitor.service
    systemctl --user start step-ca-monitor.service
    
    log_success "User systemd integration installed successfully!"
    log ""
    log "Files created:"
    log "  - $host_trust_script"
    log "  - $monitor_script"
    log "  - $USER_SYSTEMD_DIR/step-ca-monitor.service"
    log ""
    log "Service:"
    log "  - step-ca-monitor.service: Monitors step-ca container events for user $CURRENT_USER"
    log ""
    log "User Features:"
    log "  - Monitors Docker contexts for current user: $CURRENT_USER"
    log "  - Certificates named by user and context: step-ca-intermediate-$CURRENT_USER-<context>"
    log "  - Automatic updates when user switches Docker contexts"
    log "  - Real-time monitoring with inotify for Docker config changes"
    log "  - Direct access to user SSH keys for remote Docker contexts"
    log ""
    log "The certificates will be automatically updated when:"
    log "  - step-ca container restarts in current user's context"
    log "  - User switches Docker contexts (if step-ca is available)"
    log "  - Docker configuration files are modified"
}

# Uninstall user systemd integration
uninstall_user_systemd_integration() {
    log "Uninstalling user systemd integration..."
    
    local monitor_script="$USER_BIN_DIR/step-ca-user-monitor.sh"
    local host_trust_script="$USER_BIN_DIR/install-host-trust.sh"
    local service_file="$USER_SYSTEMD_DIR/step-ca-monitor.service"
    
    # Stop and disable service
    systemctl --user stop step-ca-monitor.service 2>/dev/null || true
    systemctl --user disable step-ca-monitor.service 2>/dev/null || true
    
    # Remove files
    rm -f "$service_file"
    rm -f "$monitor_script"
    rm -f "$host_trust_script"
    
    systemctl --user daemon-reload
    
    log_success "User systemd integration uninstalled successfully"
}

# Check status of user systemd integration
check_status() {
    log "Checking user systemd integration status..."
    
    echo ""
    echo "=== step-ca-monitor.service (user: $CURRENT_USER) ==="
    systemctl --user status step-ca-monitor.service --no-pager || true
    
    echo ""
    echo "=== Recent logs ==="
    journalctl --user -u step-ca-monitor.service --no-pager -n 10 || true
}

# Show usage information
show_usage() {
    echo "Usage: $0 [COMMAND]"
    echo ""
    echo "Install user systemd integration for automatic step-ca trust certificate updates"
    echo "Works with current user's Docker contexts and SSH keys"
    echo ""
    echo "Commands:"
    echo "  install     Install user systemd integration (default)"
    echo "  uninstall   Remove user systemd integration"
    echo "  status      Show status of user systemd service"
    echo "  -h, --help  Show this help message"
    echo ""
    echo "Environment Variables:"
    echo "  STEP_CA_CONTAINER_NAME    Name of step-ca container (optional, auto-detected)"
    echo ""
    echo "Examples:"
    echo "  $0                                          # Install integration for current user"
    echo "  $0 install                                  # Install integration"
    echo "  $0 uninstall                                # Remove integration"
    echo "  $0 status                                   # Check status"
    echo "  STEP_CA_CONTAINER_NAME=my-ca $0            # Use custom container name"
    echo ""
    echo "User Docker Context Support:"
    echo "  - Monitors current user ($CURRENT_USER) and their Docker contexts"
    echo "  - Automatically updates certificates when user switches contexts"
    echo "  - Certificates named by user and context: step-ca-intermediate-$CURRENT_USER-<context>"
    echo "  - Real-time monitoring with inotify for Docker config changes"
    echo "  - Direct access to user SSH keys for remote Docker contexts"
    echo ""
    echo "After installation, host trust certificates will be automatically"
    echo "updated whenever:"
    echo "  - step-ca container restarts in user's context"
    echo "  - User switches Docker contexts (if step-ca is available)"
    echo "  - Docker configuration files are modified"
    echo ""
    echo "Manual commands:"
    echo "  systemctl --user start step-ca-monitor.service     # Manual start"
    echo "  journalctl --user -u step-ca-monitor.service -f    # View logs"
    echo ""
    echo "Certificate Examples:"
    echo "  step-ca-intermediate-$CURRENT_USER-manjaro.crt     # User $CURRENT_USER, context manjaro"
    echo "  step-ca-intermediate-$CURRENT_USER-production.crt  # User $CURRENT_USER, context production"
    echo "  step-ca-intermediate-$CURRENT_USER-default.crt     # User $CURRENT_USER, context default"
}

# Main function
main() {
    local command="${1:-install}"
    
    case "$command" in
        install)
            log "Starting user systemd integration installation..."
            log "User: $CURRENT_USER"
            log "Step-CA container: ${STEP_CA_CONTAINER_NAME:-auto-detect}"
            
            # Detect distribution
            local distro=$(detect_distro)
            log "Detected distribution: $distro"
            
            # Check requirements
            if ! check_user_systemd_support; then
                exit 1
            fi
            
            if ! check_distro_requirements "$distro"; then
                exit 1
            fi
            
            if ! check_docker; then
                exit 1
            fi
            
            local trust_script
            if ! trust_script=$(check_trust_script); then
                exit 1
            fi
            
            # Setup user environment
            if ! create_user_directories; then
                exit 1
            fi
            
            # Setup certificate management group
            if ! setup_cert_group "$distro"; then
                exit 1
            fi
            
            # Install integration
            install_user_systemd_integration "$trust_script"
            ;;
        uninstall)
            log "Starting user systemd integration removal..."
            
            if ! check_user_systemd_support; then
                exit 1
            fi
            
            uninstall_user_systemd_integration
            remove_cert_group
            ;;
        status)
            check_status
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            log_error "Unknown command: $command"
            echo ""
            show_usage
            exit 1
            ;;
    esac
}

# Execute main function
main "$@"