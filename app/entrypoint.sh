#!/bin/bash
set -e

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ENTRYPOINT: $1"
}

# Signal handler for graceful shutdown
cleanup() {
    log "Received termination signal, stopping..."
    exit 0
}

trap cleanup SIGTERM SIGINT

main() {
    log "Starting custom acme-companion with step-ca integration..."
    
    # Set Docker socket for scripts
    export DOCKER_HOST=unix:///var/run/docker.sock
    
    # Execute step-ca trust bootstrap
    log "Bootstrapping step-ca trust..."
    if /app/scripts/bootstrap-step-ca.sh; then
        log "step-ca trust successfully established"
    else
        log "WARNING: Failed to establish step-ca trust, continuing anyway..."
        # Continue operation, step-ca might become available later
    fi
    
    # Setup cron jobs dynamically
    log "Setting up cron jobs..."
    if /app/scripts/setup-cron.sh; then
        log "Cron setup completed successfully"
        
        # Start cron daemon
        log "Starting cron daemon..."
        crond -b -l 2
    else
        log "WARNING: Cron setup failed, continuing without cron..."
    fi
    
    # Start docker-gen for STEP_CA_TRUST container monitoring
    log "Starting docker-gen for STEP_CA_TRUST monitoring..."
    docker-gen -config /app/docker-gen.cfg &
    
    # Start original acme-companion entrypoint
    log "Starting original acme-companion..."
    exec /app/start.sh "$@"
}

main "$@"