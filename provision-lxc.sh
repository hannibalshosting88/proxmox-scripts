#!/bin/bash
#
# Proxmox LXC Provisioning Script
# Version: 29 (Two-Command Architecture)

# --- Global Settings ---
set -Eeuo pipefail
LOG_FILE="/tmp/lxc-provisioning-$(date +%F-%H%M%S).log"
exec > >(tee -a "${LOG_FILE}") 2>&1
PS3=$'\n\t> '

# --- Helper Functions ---
log() { echo -e "\e[32m[INFO]\e[0m ===> $1" >&2; }
warn() { echo -e "\e[33m[WARN]\e[0m ==> $1" >&2; }
fail() {
    echo -e "\e[31m[FAIL]\e[0m ==> $1" >&2
    echo -e "\e[31m[FAIL]\e[0m An unrecoverable error occurred. See log: ${LOG_FILE}" >&2
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

prompt_for_selection() {
    local prompt_message=$1; shift; local options=("$@")
    log "${prompt_message}"
    select item in "${options[@]}"; do
        if [[ -n "$item" ]]; then echo "$item"; break; else warn "Invalid selection."; fi
    done < /dev/tty
}

# --- Main Execution ---
main() {
    trap 'fail "Script interrupted."' SIGINT SIGTERM
    log "Starting Generic LXC Provisioning (v29)..."

    # --- Configuration ---
    local ctid=$(find_next_id)
    read -p "--> Enter a hostname for the new container [linux-lxc]: " hostname < /dev/tty
    hostname=${hostname:-"linux-lxc"}
    read -s -p "--> Enter a secure root password for the container: " password < /dev/tty; echo
    [[ -z "$password" ]] && fail "Password cannot be empty."
    read -p "--> Enter RAM in MB [2048]: " memory < /dev/tty; memory=${memory:-2048}
    read -p "--> Enter number of CPU cores [2]: " cores < /dev/tty; cores=${cores:-2}
    read -p "--> Enter disk size in GB [10]: " rootfs_size < /dev/tty; rootfs_size=${rootfs_size:-10}

    # --- Storage & Template Selection ---
    mapfile -t root_storage_pools < <(pvesm status --content rootdir | awk 'NR>1 {print $1}')
    local rootfs_storage
    if [[ ${#root_storage_pools[@]} -eq 0 ]]; then fail "No storage for Container Disks found."; fi
    if [[ ${#root_storage_pools[@]} -eq 1 ]]; then
        rootfs_storage=${root_storage_pools[0]}
        log "Auto-selected single disk storage: ${rootfs_storage}"
    else
        rootfs_storage=$(prompt_for_selection "Select storage for the Container Disk:" "${root_storage_pools[@]}")
    fi

    mapfile -t tmpl_storage_pools < <(pvesm status --content vztmpl | awk 'NR>1 {print $1}')
    local template_storage
    if [[ ${#tmpl_storage_pools[@]} -eq 0 ]]; then fail "No storage for Templates found."; fi
    if [[ ${#tmpl_storage_pools[@]} -eq 1 ]]; then
        template_storage=${tmpl_storage_pools[0]}
        log "Auto-selected single template storage: ${template_storage}"
    else
        template_storage=$(prompt_for_selection "Select storage for Templates:" "${tmpl_storage_pools[@]}")
    fi

    local os_template
    local template_source=$(prompt_for_selection "Use a local template or download a new one?" "Use an existing local template" "Download a new template")
    case $template_source in
        "Use an existing local template")
            mapfile -t local_templates < <(pvesm list "${template_storage}" --content vztmpl | awk 'NR>1 {print $1}')
            if [[ ${#local_templates[@]} -eq 0 ]]; then fail "No local templates found on '${template_storage}'."; fi
            os_template=$(prompt_for_selection "Select a local template:" "${local_templates[@]}")
            ;;
        "Download a new template")
            log "Fetching list of available templates..."
            mapfile -t remote_templates < <(pveam available --section system | awk 'NR>1 {print $2}')
            local selected_template_file=$(prompt_for_selection "Select a template to download:" "${remote_templates[@]}")
            pveam download "${template_storage}" "${selected_template_file}" || fail "Template download failed."
            os_template="${template_storage}:vztmpl/${selected_template_file}"
            ;;
    esac
    log "Using template: ${os_template}"

    # --- Create, Configure, and Start ---
    log "Creating LXC container '${hostname}' (ID: ${ctid})..."
    pct create "${ctid}" "${os_template}" --hostname "${hostname}" --password "${password}" \
        --memory "${memory}" --cores "${cores}" --net0 name=eth0,bridge=vmbr0,ip=dhcp \
        --storage "${rootfs_storage}" --rootfs "${rootfs_storage}:${rootfs_size}" --onboot 1 --start 0 || fail "pct create failed."

    log "Configuring LXC for Docker-readiness..."
    pct set ${ctid} --features nesting=1,keyctl=1
    pct set ${ctid} --nameserver 8.8.8.8
    
    log "Starting container..."
    pct start ${ctid}
    
    # --- Final Output ---
    echo
    log "SUCCESS: Provisioning complete."
    log "Container '${hostname}' (ID: ${ctid}) is running and ready for configuration."
    echo
    log "To install the Web Desktop, run the following command:"
    local gh_user="hannibalshosting88"
    local gh_repo="proxmox-scripts"
    echo -e "\e[1;33mpct exec ${ctid} -- bash -c \"curl -sL https://raw.githubusercontent.com/${gh_user}/${gh_repo}/main/install-desktop.sh | bash\"\e[0m"
    echo
}

main "$@"
