#!/bin/bash
#
# Proxmox Interactive LXC Creator for Webtop (Docker)
# Version: 19
# - New Feature: Custom, cleaner prompt for all selection menus.

# --- Global Settings ---
set -Eeuo pipefail
LOG_FILE="/tmp/webtop-lxc-creation-$(date +%F-%H%M%S).log"
exec > >(tee -a "${LOG_FILE}") 2>&1

# MODIFICATION: Set a custom prompt for all 'select' menus.
# $'\n\t> ' creates a newline, then a tab, then the '> ' prompt.
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
    log "Starting Webtop LXC Deployment (v19)..."

    # --- Configuration ---
    local ctid=$(find_next_id)
    read -p "--> Enter a hostname for the new container [webtop]: " hostname < /dev/tty
    hostname=${hostname:-"webtop"}
    read -s -p "--> Enter a secure root password for the container: " password < /dev/tty; echo
    [[ -z "$password" ]] && fail "Password cannot be empty."
    read -p "--> Enter RAM in MB [2048]: " memory < /dev/tty; memory=${memory:-2048}
    read -p "--> Enter number of CPU cores [2]: " cores < /dev/tty; cores=${cores:-2}
    local rootfs_size="20"

    # --- Storage Selection (with auto-selection logic) ---
    local rootfs_storage
    mapfile -t root_storage_pools < <(get_storage_pools "rootdir")
    if [[ ${#root_storage_pools[@]} -eq 0 ]]; then
        fail "No storage for Container Disks found."
    elif [[ ${#root_storage_pools[@]} -eq 1 ]]; then
        rootfs_storage=${root_storage_pools[0]}
        log "Auto-selected single available disk storage: ${rootfs_storage}"
    else
        rootfs_storage=$(select_from_list "Select storage for the Container Disk:" root_storage_pools)
    fi

    local template_storage
    mapfile -t tmpl_storage_pools < <(get_storage_pools "vztmpl")
    if [[ ${#tmpl_storage_pools[@]} -eq 0 ]]; then
        fail "No storage for Templates found."
    elif [[ ${#tmpl_storage_pools[@]} -eq 1 ]]; then
        template_storage=${tmpl_storage_pools[0]}
        log "Auto-selected single available template storage: ${template_storage}"
    else
        template_storage=$(select_from_list "Select storage for Templates:" tmpl_storage_pools)
    fi

    # --- Template Selection (with Local/Download choice) ---
    local os_template
    log "Use a local template or download a new one?"
    select template_source in "Use an existing local template" "Download a new template"; do
        case $template_source in
            "Use an existing local template")
                mapfile -t local_templates < <(get_local_templates "${template_storage}")
                if [[ ${#local_templates[@]} -eq 0 ]]; then
                    fail "No local templates found on storage '${template_storage}'. Please choose the download option instead."
                fi
                local selected_template_opt=$(select_from_list "Select a local template:" local_templates)
                os_template="${selected_template_opt}"
                break
                ;;
            "Download a new template")
                log "Fetching list of available templates from Proxmox..."
                mapfile -t remote_templates < <(pveam available --section system | awk 'NR>1 {print $2}')
                local selected_template_file=$(select_from_list "Select a template to download:" remote_templates)
                log "Downloading ${selected_template_file} to '${template_storage}'..."
                pveam download "${template_storage}" "${selected_template_file}" || fail "Template download failed."
                os_template="${template_storage}:vztmpl/${selected_template_file}"
                break
                ;;
        esac
    done < /dev/tty
    log "Selected template: ${os_template}"

    # --- Create, Configure, and Deploy ---
    log "Creating LXC container '${hostname}' (ID: ${ctid})..."
    pct create "${ctid}" "${os_template}" --hostname "${hostname}" --password "${password}" \
        --memory "${memory}" --cores "${cores}" --net0 name=eth0,bridge=vmbr0,ip=dhcp \
        --storage "${rootfs_storage}" --rootfs "${rootfs_storage}:${rootfs_size}" --onboot 1 --start 0 || fail "pct create failed."

    log "Configuring LXC for Docker support..."
    pct set ${ctid} --features nesting=1,keyctl=1
    # Set a reliable DNS server to ensure network access on boot
    pct set ${ctid} --nameserver 8.8.8.8
    
    log "Starting container..."
    pct start ${ctid}
    
    log "Pausing for 5 seconds to allow container to settle..."
    sleep 5
    
    log "Waiting for network to become fully operational..."

    local attempts=0
    # Loop until we can successfully ping Google's DNS, with a 30-second timeout.
    while ! pct exec "${ctid}" -- ping -c 1 -W 2 8.8.8.8 &>/dev/null; do
        ((attempts++))
        if [ "$attempts" -ge 15 ]; then
            fail "Network did not come online within 30 seconds."
        fi
        sleep 2
    done
    log "Network is online."

    log "Installing Docker..."
    pct exec "${ctid}" -- bash -c "apt-get update && apt-get install -y curl && curl -fsSL https://get.docker.com | sh" || fail "Docker installation failed."

    log "Deploying Webtop container..."
    local webtop_cmd="docker run -d --name=webtop -e PUID=1000 -e PGID=1000 -e DOCKER_MODS=linuxserver/mods:webtop-xrdp -p 3000:3000 -v webtop-config:/config --shm-size=\"1gb\" --security-opt apparmor=unconfined --restart unless-stopped lscr.io/linuxserver/webtop:latest"
    pct exec "${ctid}" -- bash -c "$webtop_cmd" || fail "Webtop docker container deployment failed."

    local container_ip=$(pct exec ${ctid} -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    log "SUCCESS: Deployment complete."
    log "Webtop is accessible at: http://${container_ip}:3000"
}

main "$@"
