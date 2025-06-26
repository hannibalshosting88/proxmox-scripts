#!/bin/bash
#
# Proxmox Interactive LXC Creator for Webtop (Docker)
# Version: 16
# Features:
# - Auto-detects next available LXC ID.
# - Prompts for storage for Root Disk and Templates (handles split storage).
# - Lists and allows selection of existing templates.
# - Offers to download Debian 12 template if none are available.
# - Dynamically determines OS to use correct package manager.
# - Full logging to /tmp/

# --- Global Settings ---
set -Eeuo pipefail # Fail fast, trace errors
LOG_FILE="/tmp/webtop-lxc-creation-$(date +%F-%H%M%S).log"
exec > >(tee -a "${LOG_FILE}") 2>&1 # Redirect all output to log and stdout

# --- Helper Functions ---
log() {
    echo "[INFO] ===> $1"
}

warn() {
    echo "[WARN] ==> $1" >&2
}

fail() {
    echo "[FAIL] ==> $1" >&2
    echo "[FAIL] An unrecoverable error occurred. See log for details: ${LOG_FILE}" >&2
    exit 1
}

# Finds the next available LXC container ID
find_next_id() {
    log "Searching for the next available LXC ID..." >&2
    local last_id=$(pct list | awk 'NR>1 {print $1}' | sort -n | tail -1)
    local next_id=$((last_id + 1))
    # In case there are no containers, start at 100
    [[ -z "$last_id" ]] && next_id=100

    while pct status "$next_id" &>/dev/null; do
        ((next_id++))
    done
    log "Next available ID is ${next_id}" >&2
    echo "$next_id"
}
# Gets a list of active, non-directory storage pools
get_storage_pools() {
    pvesm status -content images,rootdir | awk 'NR>1 {print $1}'
}

# Interactive prompt to select a storage pool
select_storage() {
    local prompt_message=$1
    local -n storage_pools_ref=$2 # Pass array by reference
    local selected_storage

    log "${prompt_message}"
    select opt in "${storage_pools_ref[@]}"; do
        if [[ -n "$opt" ]]; then
            selected_storage=$opt
            break
        else
            warn "Invalid selection. Please try again."
        fi
    done
    echo "$selected_storage"
}
# Gets a list of local templates from a given storage pool
get_local_templates() {
    local storage=$1
    log "Checking for existing templates on '${storage}'..."
    # pvesm list returns an error if no templates found, so we suppress it
    pvesm list "${storage}" --content vztmpl | awk 'NR>1 {print $2}' || true
}

# Interactive prompt to select a template or download a new one
select_template() {
    local template_storage=$1
    local os_template
    local template_options=()
    local local_templates

    local_templates=$(get_local_templates "${template_storage}")

    if [[ -n "$local_templates" ]]; then
        mapfile -t template_options <<< "$local_templates"
        log "Found existing templates."
    else
        warn "No existing templates found on '${template_storage}'."
    fi

    template_options+=("DOWNLOAD_NEW_DEBIAN_12")
    template_options+=("EXIT")

    log "Please select a container template:"
    select opt in "${template_options[@]}"; do
        case "$opt" in
            "DOWNLOAD_NEW_DEBIAN_12")
                local new_template_name="debian-12-standard_12.2-1_amd64.tar.zst"
                log "Downloading Debian 12 template..."
                pveam download "${template_storage}" "${new_template_name}" || fail "Template download failed."
                os_template="${template_storage}:vztmpl/${new_template_name}"
                break
                ;;
            "EXIT")
                fail "User aborted."
                ;;
            *)
                if [[ -n "$opt" ]]; then
                    os_template="${template_storage}:vztmpl/${opt}"
                    break
                else
                    warn "Invalid selection. Try again."
                fi
                ;;
        esac
    done
    echo "$os_template"
}
# --- Main Execution ---
main() {
    trap 'fail "Script interrupted."' SIGINT SIGTERM

    log "Starting Webtop LXC Deployment..."

    # --- Get Configuration ---
    local ctid=$(find_next_id)
    read -p "--> Enter a hostname for the new container [webtop-${ctid}]: " hostname < /dev/tty
    hostname=${hostname:-"webtop-${ctid}"}

    read -s -p "--> Enter a secure root password for the container: " password < /dev/tty
    echo
    [[ -z "$password" ]] && fail "Password cannot be empty."

    read -p "--> Enter RAM in MB [2048]: " memory < /dev/tty
    memory=${memory:-2048}

    read -p "--> Enter number of CPU cores [2]: " cores < /dev/tty
    cores=${cores:-2}

    # --- Storage Selection ---
    mapfile -t all_storage < <(get_storage_pools)
    [[ ${#all_storage[@]} -eq 0 ]] && fail "No suitable storage found."

    local rootfs_storage=$(select_storage "Select storage for the Container Disk (RootFS):" all_storage)
    local template_storage=$(select_storage "Select storage for Templates:" all_storage)
    local rootfs_size="20G" # Set a default size

    # --- Template Selection ---
    local os_template=$(select_template "${template_storage}")
    log "Selected template: ${os_template}"

    # --- Create LXC ---
    log "Creating LXC container '${hostname}' (ID: ${ctid})..."
    pct create "${ctid}" "${os_template}" --hostname "${hostname}" --password "${password}" \
        --memory "${memory}" --cores "${cores}" --net0 name=eth0,bridge=vmbr0,ip=dhcp \
        --storage "${rootfs_storage}" --rootfs "${rootfs_storage}:${rootfs_size}" --onboot 1 --start 1 || fail "pct create failed."

    log "Waiting for container to boot and acquire IP..."
    sleep 10 # Give it time to get an IP via DHCP

    # --- Install Dependencies ---
    log "Installing dependencies inside the container..."
    local os_type=$(basename "$os_template" | cut -d'-' -f1)
    local pkg_manager="apt-get" && local install_cmd="install -y"
    if [[ "$os_type" == "alpine" ]]; then
        pkg_manager="apk" && install_cmd="add"
    fi

    pct exec "${ctid}" -- bash -c "for i in {1..5}; do ${pkg_manager} update && break || sleep 5; done" || fail "Package list update failed."
    pct exec "${ctid}" -- bash -c "${pkg_manager} ${install_cmd} curl docker.io" || fail "Dependency installation failed."

    # --- Deploy Webtop ---
    log "Deploying Webtop using Docker..."
    pct exec "${ctid}" -- bash -c "systemctl enable --now docker" || warn "Could not enable docker service. May already be running."
    
    local webtop_cmd="docker run -d --name=webtop -e PUID=1000 -e PGID=1000 -p 3000:3000 -v webtop-config:/config --shm-size=\"1gb\" --restart unless-stopped lscr.io/linuxserver/webtop:latest"
    pct exec "${ctid}" -- bash -c "$webtop_cmd" || fail "Webtop docker container deployment failed."

    local container_ip=$(pct exec ${ctid} -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    log "SUCCESS: Deployment complete."
    log "Webtop is accessible at: http://${container_ip}:3000"
    log "Full log available at: ${LOG_FILE}"
}

main "$@"