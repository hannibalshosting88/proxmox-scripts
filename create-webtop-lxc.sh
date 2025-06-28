#!/bin/bash
#
# Proxmox Interactive LXC Creator for an Ephemeral Web Desktop
# Version: 24 (Production)
# - Deploys a stable LXDE desktop via dorowu/ubuntu-desktop-lxde-vnc

# --- Global Settings ---
set -Eeuo pipefail
LOG_FILE="/tmp/desktop-lxc-creation-$(date +%F-%H%M%S).log"
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

# --- Main Execution ---
main() {
    trap 'fail "Script interrupted."' SIGINT SIGTERM
    log "Starting Web Desktop LXC Deployment (v24)..."

    # --- Configuration ---
    local ctid=$(find_next_id)
    read -p "--> Enter a hostname for the new container [web-desktop]: " hostname < /dev/tty
    hostname=${hostname:-"web-desktop"}
    read -s -p "--> Enter a secure root password for the container: " password < /dev/tty; echo
    [[ -z "$password" ]] && fail "Password cannot be empty."
    read -p "--> Enter RAM in MB [2048]: " memory < /dev/tty; memory=${memory:-2048}
    read -p "--> Enter number of CPU cores [2]: " cores < /dev/tty; cores=${cores:-2}
    local rootfs_size="10"

    # --- Storage & Template Selection ---
    mapfile -t root_storage_pools < <(get_storage_pools "rootdir")
    [[ ${#root_storage_pools[@]} -eq 0 ]] && fail "No storage for Container Disks found."
    local rootfs_storage=$(select_from_list "Select storage for the Container Disk:" root_storage_pools)

    mapfile -t tmpl_storage_pools < <(get_storage_pools "vztmpl")
    [[ ${#tmpl_storage_pools[@]} -eq 0 ]] && fail "No storage for Templates found."
    local template_storage=$(select_from_list "Select storage for Templates:" tmpl_storage_pools)
    
    log "Using Debian 12 as the base template."
    local found_template=$(pvesm list "${template_storage}" --content vztmpl | grep "debian-12" | awk '{print $1}' | head -n 1)
    local os_template
    if [[ -n "$found_template" ]]; then
        log "Found existing template: ${found_template}"
        os_template=$found_template
    else
        warn "No Debian 12 template found. Downloading a new one..."
        local new_template_name="debian-12-standard_12.2-1_amd64.tar.zst"
        pveam download "${template_storage}" "${new_template_name}" || fail "Template download failed."
        os_template="${template_storage}:vztmpl/${new_template_name}"
    fi
    log "Using template: ${os_template}"

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

    log "Deploying LXDE Desktop container..."
    local desktop_cmd="docker run -d -p 6080:80 --name=lxde-desktop dorowu/ubuntu-desktop-lxde-vnc"
    pct exec "${ctid}" -- bash -c "$desktop_cmd" || fail "Desktop container deployment failed."

    local container_ip=$(pct exec ${ctid} -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    log "SUCCESS: Deployment complete."
    log "The Web Desktop is accessible at: http://${container_ip}:6080"
}

main "$@"
