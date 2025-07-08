#!/bin/bash
set -e

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] CRON-SETUP: $1"
}

# Default values
DEFAULT_CRON_SCHEDULE="0 */6 * * *"
DEFAULT_CRON_ENABLED="true"
DEFAULT_CRON_LOG_LEVEL="2"

# Get configuration from environment variables
CRON_SCHEDULE="${CRON_SCHEDULE:-$DEFAULT_CRON_SCHEDULE}"
CRON_ENABLED="${CRON_ENABLED:-$DEFAULT_CRON_ENABLED}"
CRON_LOG_LEVEL="${CRON_LOG_LEVEL:-$DEFAULT_CRON_LOG_LEVEL}"

# Validate cron schedule format
validate_cron_schedule() {
    local schedule="$1"
    
    # Basic validation: should have 5 fields separated by spaces
    local field_count=$(echo "$schedule" | wc -w)
    if [ "$field_count" -ne 5 ]; then
        log "ERROR: Invalid cron schedule format: '$schedule' (expected 5 fields)"
        return 1
    fi
    
    # Check for dangerous characters
    if echo "$schedule" | grep -q '[;&|`$()]'; then
        log "ERROR: Cron schedule contains dangerous characters: '$schedule'"
        return 1
    fi
    
    log "Cron schedule validation passed: '$schedule'"
    return 0
}

# Setup cron job
setup_cron_job() {
    log "Setting up cron job with schedule: '$CRON_SCHEDULE'"
    
    # Validate schedule
    if ! validate_cron_schedule "$CRON_SCHEDULE"; then
        log "ERROR: Invalid cron schedule, using default: '$DEFAULT_CRON_SCHEDULE'"
        CRON_SCHEDULE="$DEFAULT_CRON_SCHEDULE"
    fi
    
    # Create crontab content
    local crontab_content="# Trust certificate processing cron job
# Generated dynamically from CRON_SCHEDULE environment variable
$CRON_SCHEDULE /app/scripts/trust-processor.sh >> /var/log/trust-processor.log 2>&1
"
    
    # Write crontab file
    echo "$crontab_content" > /etc/crontabs/root
    
    log "Crontab file created successfully"
    log "Cron job: $CRON_SCHEDULE /app/scripts/trust-processor.sh"
    
    return 0
}

# Main function
main() {
    log "Starting cron setup..."
    log "CRON_ENABLED: $CRON_ENABLED"
    log "CRON_SCHEDULE: $CRON_SCHEDULE"
    log "CRON_LOG_LEVEL: $CRON_LOG_LEVEL"
    
    # Check if cron is enabled
    if [ "$CRON_ENABLED" != "true" ]; then
        log "Cron is disabled (CRON_ENABLED=$CRON_ENABLED), skipping setup"
        return 0
    fi
    
    # Setup cron job
    if setup_cron_job; then
        log "Cron setup completed successfully"
        return 0
    else
        log "ERROR: Cron setup failed"
        return 1
    fi
}

# Execute main function if script is called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi