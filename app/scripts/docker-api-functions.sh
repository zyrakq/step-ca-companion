#!/bin/bash

# Docker API functions (adapted from step-companion)

## Docker API
docker_api() {
    local scheme
    local curl_opts=(-s)
    local method=${2:-GET}
    
    if [[ -n "${3:-}" ]]; then
        curl_opts+=(-d "$3")
    fi
    
    if [[ -z "$DOCKER_HOST" ]]; then
        echo "Error: DOCKER_HOST variable not set" >&2
        return 1
    fi
    
    if [[ $DOCKER_HOST == unix://* ]]; then
        curl_opts+=(--unix-socket "${DOCKER_HOST#unix://}")
        scheme='http://localhost'
    else
        scheme="http://${DOCKER_HOST#*://}"
    fi
    
    [[ $method = "POST" ]] && curl_opts+=(-H 'Content-Type: application/json')
    curl "${curl_opts[@]}" -X "${method}" "${scheme}$1"
}

labeled_cid() {
    docker_api "/containers/json" | jq -r '.[] | select(.Labels["'"$1"'"])|.Id'
}

get_step_ca_container() {
    local step_ca_cid=""
    
    # Priority 1: Docker Labels
    local legacy_step_ca_cid; legacy_step_ca_cid="$(labeled_cid com.github.jrcs.letsencrypt_step_ca_companion.step_ca | head -n1)"
    local new_step_ca_cid; new_step_ca_cid="$(labeled_cid com.smallstep.step-ca | head -n1)"
    local generic_step_ca_cid; generic_step_ca_cid="$(labeled_cid com.github.step-ca.step-ca | head -n1)"
    step_ca_cid="${new_step_ca_cid:-${generic_step_ca_cid:-$legacy_step_ca_cid}}"

    # Priority 2: Environment variable (with existence check)
    if [[ -z "${step_ca_cid}" && -n "${STEP_CA_CONTAINER_NAME:-}" ]]; then
        step_ca_cid="$(docker_api "/containers/json" | jq -r '.[] | select(.Names[] | test("^/'$STEP_CA_CONTAINER_NAME'$")) | .Id' | head -n1)"
        if [[ -z "$step_ca_cid" ]]; then
            echo "WARNING: Container '$STEP_CA_CONTAINER_NAME' not found, trying auto-detection" >&2
        fi
    fi
    
    # Priority 3: Auto-detection - search for containers ending EXACTLY with step-ca
    if [[ -z "$step_ca_cid" ]]; then
        # Method 1: Search by step-ca environment variables AND name ending EXACTLY with step-ca
        step_ca_cid="$(docker_api "/containers/json" | jq -r '.[] | select(.Config.Env[]? | test("^DOCKER_STEPCA_")) | select(.Names[]? | test("/step-ca$"; "i")) | .Id' | head -n1)"
        
        # Method 2: Search by port 9000 AND name ending EXACTLY with step-ca
        if [[ -z "$step_ca_cid" ]]; then
            step_ca_cid="$(docker_api "/containers/json" | jq -r '.[] | select(.Ports[]? | .PrivatePort == 9000) | select(.Names[]? | test("/step-ca$"; "i")) | .Id' | head -n1)"
        fi
        
        # Method 3: Search only by container name ending EXACTLY with step-ca
        if [[ -z "$step_ca_cid" ]]; then
            step_ca_cid="$(docker_api "/containers/json" | jq -r '.[] | select(.Names[]? | test("/step-ca$"; "i")) | .Id' | head -n1)"
        fi
    fi

    # Return container ID if found
    [[ -n "$step_ca_cid" ]] && echo "$step_ca_cid"
}

get_container_name() {
    local container_id="$1"
    docker_api "/containers/$container_id/json" | jq -r '.Name' | sed 's/^\///'
}

is_container_running() {
    local container_id="$1"
    local status=$(docker_api "/containers/$container_id/json" | jq -r '.State.Status' 2>/dev/null)
    [[ "$status" = "running" ]]
}
