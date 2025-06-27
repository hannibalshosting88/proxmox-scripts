#!/bin/bash
#
# Proxmox Interactive LXC Creator for a basic Docker container
# Version: 21 (Stable Base)
# - Switched to a guaranteed-stable Docker image for final testing.

# --- Global Settings ---
set -Eeuo pipefail
LOG_FILE="/tmp/docker-lxc-creation-$(date +%F-%H%M%S).log"
exec > >(tee -a "${LOG_FILE}") 2>&1
PS3=$'\n\t> '

# --- Helper Functions ---
log() { echo "[INFO] ===> $1" >&2; }
warn() { echo "[WARN] ==> $1" >&2; }
fail() {
    echo "[FAIL] ==> $1" >&2
    echo "[FAIL] An unrecoverable error occurred. See log for details: ${LOG_FILE}" >&2
    exit 1
}

find_next_id() {
    log "Searching for the first available LXC/VM ID from 100 upwards..."
    local id=100
    while pct status "$id" &>/dev/null || qm status "$id" &>/dev/null; do
        ((id++))
    done
    log "First available ID is ${id}"
    echo "$id"
}

get_storage_pools() {
    local content_type=$1
    pvesm status --content "${content_type}" | awk 'NR>1 {print $1}'
}

select_from_list() {
    local prompt_message=$1
    local -n options_ref=$2
    local selected_item

    log "${prompt_message}"
    select opt in "${options_ref[@]}"; do
        if [[ -n "$opt" ]]; then
            selected_item=$opt
            break
        else
            warn "Invalid selection. Please try again."
        fi
    done < /dev/tty
    echo "$selected_item"
}

get_local_templates() {
    local storage=$1
    log "Checking for existing templates on '${storage}'..."
    pvesm list "${storage}" --content vztmpl | awk 'NR>1 {print $1}' || true
}

# --- Main Execution ---
main() {
    trap 'fail "Script interrupted."' SIGINT SIGTERM
    log "Starting Docker LXC Deployment (v21)..."

    # --- Configuration ---
    local ctid=$(find_next_id)
    read -p "--> Enter a hostname for the new container [docker-host]: " hostname < /dev/tty
    hostname=${hostname:-"docker-host"}
    read -s -p "--> Enter a secure root password for the container: " password < /dev/tty; echo
    [[ -z "$password" ]] && fail "Password cannot be empty."
    read -p "--> Enter RAM in MB [1024]: " memory < /dev/tty; memory=${memory:-1024}
    read -p "--> Enter number of CPU cores [1]: " cores < /dev/tty; cores=${cores:-1}
    local rootfs_size="10"

    # --- Storage & Template Selection ---
    mapfile -t root_storage_pools < <(get_storage_pools "rootdir")
    [[ ${#root_storage_pools[@]} -eq 0 ]] && fail "No storage for Container Disks found."
    local rootfs_storage=$(select_from_list "Select storage for the Container Disk:" root_storage_pools)

    mapfile -t tmpl_storage_pools < <(get_storage_pools "vztmpl")
    [[ ${#tmpl_storage_pools[@]} -eq 0 ]] && fail "No storage for Templates found."
    local template_storage=$(select_from_list "Select storage for Templates:" tmpl_storage_pools)
    
    log "Using Debian 12 as the base template for this test."
    local new_template="debian-12-standard_12.2-1_amd64.tar.zst"
    pveam download "${template_storage}" "${new_template}" >/dev/null 2>&1 || log "Template already exists. Continuing."
    local os_template="${template_storage}:vztmpl/${new_template}"

    # --- Create, Configure, and Deploy ---
    log "Creating LXC container '${hostname}' (ID: ${ctid})..."
    pct create "${ctid}" "${os_template}" --hostname "${hostname}" --password "${password}" \
        --memory "${memory}" --cores "${cores}" --net0 name=eth0,bridge=vmbr0,ip=dhcp \
        --storage "${rootfs_storage}" --rootfs "${rootfs_storage}:${rootfs_size}" --onboot 1 --start 0 || fail "pct create failed."

    log "Configuring LXC for Docker support..."
    pct set ${ctid} --features nesting=1,keyctl=1
    pct set ${ctid} --nameserver 8.8.8.8
    
    log "Starting container and waiting for network..."
    pct start ${ctid}
    sleep 5 # Settle time
    local attempts=0
    while ! pct exec "${ctid}" -- ping -c 1 -W 2 8.8.8.8 &>/dev/null; do
        ((attempts++)); if [ "$attempts" -ge 15 ]; then fail "Network did not come online."; fi; sleep 2
    done
    log "Network is online."

    log "Installing Docker..."
    pct exec "${ctid}" -- bash -c "apt-get update && apt-get install -y curl && curl -fsSL https://get.docker.com | sh" || fail "Docker installation failed."

    log "Deploying a simple test container..."
    local test_cmd="docker run -d -p 8080:80 docker/getting-started"
    pct exec "${ctid}" -- bash -c "$test_cmd" || fail "Test docker container deployment failed."

    local container_ip=$(pct exec ${ctid} -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    log "SUCCESS: Deployment complete."
    log "The test container is accessible at: http://${container_ip}:8080"
}

main "$@"
