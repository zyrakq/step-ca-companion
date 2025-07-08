#!/bin/bash

# OS Detection functions for container trust certificate installation

# Set Docker socket path
export DOCKER_HOST=unix:///var/run/docker.sock

log_os() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] OS-DETECTION: $1"
}

# Detect OS type in a container
detect_container_os() {
    local container_id="$1"
    
    log_os "Detecting OS for container: $container_id" >&2
    
    # Try to detect OS by checking release files
    if docker exec "$container_id" test -f /etc/os-release 2>/dev/null; then
        local os_info=$(docker exec "$container_id" cat /etc/os-release 2>/dev/null)
        
        if echo "$os_info" | grep -qi "ubuntu"; then
            echo "ubuntu"
            return 0
        elif echo "$os_info" | grep -qi "debian"; then
            echo "debian"
            return 0
        elif echo "$os_info" | grep -qi "alpine"; then
            echo "alpine"
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
        fi
    fi
    
    # Fallback: try to detect by package managers
    if docker exec "$container_id" which apt-get >/dev/null 2>&1; then
        echo "debian"
        return 0
    elif docker exec "$container_id" which apk >/dev/null 2>&1; then
        echo "alpine"
        return 0
    elif docker exec "$container_id" which yum >/dev/null 2>&1; then
        echo "rhel"
        return 0
    elif docker exec "$container_id" which dnf >/dev/null 2>&1; then
        echo "fedora"
        return 0
    elif docker exec "$container_id" which pacman >/dev/null 2>&1; then
        echo "arch"
        return 0
    fi
    
    # If nothing detected, return unknown
    log_os "WARNING: Could not detect OS for container $container_id" >&2
    echo "unknown"
    return 1
}

# Get package manager command for OS
get_package_manager() {
    local os_type="$1"
    
    case "$os_type" in
        "ubuntu"|"debian")
            echo "apt-get"
            ;;
        "alpine")
            echo "apk"
            ;;
        "rhel"|"centos")
            echo "yum"
            ;;
        "fedora")
            echo "dnf"
            ;;
        "arch")
            echo "pacman"
            ;;
        *)
            echo "unknown"
            return 1
            ;;
    esac
}

# Get package installation command
get_install_command() {
    local os_type="$1"
    local package="$2"
    
    case "$os_type" in
        "ubuntu"|"debian")
            echo "apt-get update && apt-get install -y $package"
            ;;
        "alpine")
            echo "apk add --no-cache $package"
            ;;
        "rhel"|"centos")
            echo "yum install -y $package"
            ;;
        "fedora")
            echo "dnf install -y $package"
            ;;
        "arch")
            echo "pacman -Sy --noconfirm $package"
            ;;
        *)
            echo ""
            return 1
            ;;
    esac
}

# Get certificate directory path for OS
get_cert_directory() {
    local os_type="$1"
    
    case "$os_type" in
        "ubuntu"|"debian"|"alpine")
            echo "/usr/local/share/ca-certificates"
            ;;
        "rhel"|"centos"|"fedora")
            echo "/etc/pki/ca-trust/source/anchors"
            ;;
        "arch")
            echo "/etc/ca-certificates/trust-source/anchors"
            ;;
        *)
            echo ""
            return 1
            ;;
    esac
}

# Get trust update command for OS
get_trust_update_command() {
    local os_type="$1"
    
    case "$os_type" in
        "ubuntu"|"debian"|"alpine")
            echo "update-ca-certificates"
            ;;
        "rhel"|"centos"|"fedora")
            echo "update-ca-trust"
            ;;
        "arch")
            echo "trust extract-compat"
            ;;
        *)
            echo ""
            return 1
            ;;
    esac
}

# Check if container is running
is_container_running() {
    local container_id="$1"
    
    if docker inspect "$container_id" --format='{{.State.Running}}' 2>/dev/null | grep -q "true"; then
        return 0
    else
        return 1
    fi
}