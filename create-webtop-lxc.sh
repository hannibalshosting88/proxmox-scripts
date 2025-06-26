#!/bin/bash
#
# Proxmox Interactive LXC Creator for Webtop (Docker)
# Version: 17 (Definitive)
# - Merges best logic from user-provided script (v15)
# - Globally fixes output pollution bug by redirecting logs to stderr.
# - Integrates superior ID finding logic.
# - Automatically preps LXC for Docker nesting.

# --- Global Settings ---
set -Eeuo pipefail
LOG_FILE="/tmp/webtop-lxc-creation-$(date +%F-%H%M%S).log"
exec > >(tee -a "${LOG_FILE}") 2>&1

# --- Helper Functions ---
# All log functions now write to STDERR to avoid polluting command substitution
log() { echo "[INFO] ===> $1" >&2; }
warn() { echo "[WARN] ==> $1" >&2; }
fail() {
    echo "[FAIL] ==> $1" >&2
    echo "[FAIL] An unrecoverable error occurred. See log for details: ${LOG_FILE}" >&2
    exit 1
}

# Finds the first available LXC/VM ID, starting from 100
find_next_id() {
    log "Searching for the first available LXC/VM ID from 100 upwards..." >&2
    local id=100
    while pct status "$id" &>/dev/null || qm status "$id" &>/dev/null; do
        ((id++))
    done
    log "First available ID is ${id}" >&2
    echo "$id"
}

# Gets a list of active, non-directory storage pools for a given content type
get_storage_pools() {
    local content_type=$1
    pvesm status --content "${content_type}" | awk 'NR>1 {print $1}'
}

# Interactive prompt to select an item from a list
select_from_list() {
    local prompt_message=$1
    local -n options_ref=$2 # Pass array by reference
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

# Gets a list of local templates from a given storage pool
get_local_templates() {
    local storage=$1
    log "Checking for existing templates on '${storage}'..." >&2
    # Use awk to split by '/' and print the last field (the filename)
    pvesm list "${storage}" --content vztmpl | awk -F/ 'NR>1 {print $NF}' || true
}

# --- Main Execution ---
main() {
    trap 'fail "Script interrupted."' SIGINT SIGTERM
    log "Starting Webtop LXC Deployment (v17)..."

    # --- Configuration ---
    local ctid=$(find_next_id)
    read -p "--> Enter a hostname for the new container [webtop-${ctid}]: " hostname < /dev/tty
    hostname=${hostname:-"webtop-${ctid}"}
    read -s -p "--> Enter a secure root password for the container: " password < /dev/tty; echo
    [[ -z "$password" ]] && fail "Password cannot be empty."
    read -p "--> Enter RAM in MB [2048]: " memory < /dev/tty; memory=${memory:-2048}
    read -p "--> Enter number of CPU cores [2]: " cores < /dev/tty; cores=${cores:-2}
    local rootfs_size="20G"

    # --- Storage & Template Selection ---
    mapfile -t root_storage_pools < <(get_storage_pools "rootdir")
    [[ ${#root_storage_pools[@]} -eq 0 ]] && fail "No storage for Container Disks found."
    local rootfs_storage=$(select_from_list "Select storage for the Container Disk:" root_storage_pools)

    mapfile -t tmpl_storage_pools < <(get_storage_pools "vztmpl")
    [[ ${#tmpl_storage_pools[@]} -eq 0 ]] && fail "No storage for Templates found."
    local template_storage=$(select_from_list "Select storage for Templates:" tmpl_storage_pools)

    mapfile -t template_options < <(get_local_templates "${template_storage}")
    template_options+=("DOWNLOAD_NEW_DEBIAN_12")
    local selected_template_opt=$(select_from_list "Select a container template:" template_options)
    local os_template

    if [[ "$selected_template_opt" == "DOWNLOAD_NEW_DEBIAN_12" ]]; then
        local new_template="debian-12-standard_12.2-1_amd64.tar.zst"
        log "Downloading Debian 12 template to '${template_storage}'..."
        pveam download "${template_storage}" "${new_template}" || fail "Template download failed."
        os_template="${template_storage}:vztmpl/${new_template}"
    else
        os_template="${template_storage}:vztmpl/${selected_template_opt}"
    fi
    log "Selected template: ${os_template}"

    # --- Create and Configure LXC ---
    log "Creating LXC container '${hostname}' (ID: ${ctid})..."
    pct create "${ctid}" "${os_template}" --hostname "${hostname}" --password "${password}" \
        --memory "${memory}" --cores "${cores}" --net0 name=eth0,bridge=vmbr0,ip=dhcp \
        --storage "${rootfs_storage}" --rootfs "${rootfs_storage}:${rootfs_size}" --onboot 1 --start 0 || fail "pct create failed."

    log "Configuring LXC for Docker support..."
    pct set ${ctid} --features nesting=1,keyctl=1
    
    log "Starting container..."
    pct start ${ctid}
    sleep 10

    # --- Install Dependencies & Deploy Webtop ---
    log "Installing Docker..."
    pct exec "${ctid}" -- bash -c "apt-get update && apt-get install -y curl && curl -fsSL https://get.docker.com | sh" || fail "Docker installation failed."

    log "Deploying Webtop container..."
    local webtop_cmd="docker run -d --name=webtop -e PUID=1000 -e PGID=1000 -p 3000:3000 -v webtop-config:/config --shm-size=\"1gb\" --restart unless-stopped lscr.io/linuxserver/webtop:latest"
    pct exec "${ctid}" -- bash -c "$webtop_cmd" || fail "Webtop docker container deployment failed."

    local container_ip=$(pct exec ${ctid} -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    log "SUCCESS: Deployment complete."
    log "Webtop is accessible at: http://${container_ip}:3000"
}

main "$@"
