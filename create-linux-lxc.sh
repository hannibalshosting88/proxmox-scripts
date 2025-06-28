#!/bin/bash
#
# Proxmox LXC Provisioning Script
# Version: 28 (Final Syntax Fix)

# --- Global Settings ---
set -Eeuo pipefail
LOG_FILE="/tmp/lxc-provisioning-$(date +%F-%H%M%S).log"
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

# BUG FIX: Renamed custom function from 'select' to 'prompt_for_selection'
# to avoid conflict with the Bash 'select' reserved keyword.
prompt_for_selection() {
    local prompt_message=$1
    shift
    local options=("$@")
    
    log "${prompt_message}"
    select item in "${options[@]}"; do
        if [[ -n "$item" ]]; then
            echo "$item"
            break
        else
            warn "Invalid selection. Please try again."
        fi
    done < /dev/tty
}

# --- Main Execution ---
main() {
    trap 'fail "Script interrupted."' SIGINT SIGTERM
    log "Starting Generic LXC Provisioning (v28)..."

    # --- Configuration ---
    local ctid=$(find_next_id)
    read -p "--> Enter a hostname for the new container [linux-desktop]: " hostname < /dev/tty
    hostname=${hostname:-"linux-desktop"}
    read -s -p "--> Enter a secure root password for the container: " password < /dev/tty; echo
    [[ -z "$password" ]] && fail "Password cannot be empty."
    read -p "--> Enter RAM in MB [2048]: " memory < /dev/tty; memory=${memory:-2048}
    read -p "--> Enter number of CPU cores [2]: " cores < /dev/tty; cores=${cores:-2}
    read -p "--> Enter disk size in GB [10]: " rootfs_size < /dev/tty; rootfs_size=${rootfs_size:-10}

    # --- Storage Selection ---
    mapfile -t root_storage_pools < <(pvesm status --content rootdir | awk 'NR>1 {print $1}')
    if [[ ${#root_storage_pools[@]} -eq 0 ]]; then fail "No storage for Container Disks found."; fi
    local rootfs_storage
    if [[ ${#root_storage_pools[@]} -eq 1 ]]; then
        rootfs_storage=${root_storage_pools[0]}
        log "Auto-selected single available disk storage: ${rootfs_storage}"
    else
        rootfs_storage=$(prompt_for_selection "Select storage for the Container Disk:" "${root_storage_pools[@]}")
    fi

    mapfile -t tmpl_storage_pools < <(pvesm status --content vztmpl | awk 'NR>1 {print $1}')
    if [[ ${#tmpl_storage_pools[@]} -eq 0 ]]; then fail "No storage for Templates found."; fi
    local template_storage
    if [[ ${#tmpl_storage_pools[@]} -eq 1 ]]; then
        template_storage=${tmpl_storage_pools[0]}
        log "Auto-selected single available template storage: ${template_storage}"
    else
        template_storage=$(prompt_for_selection "Select storage for Templates:" "${tmpl_storage_pools[@]}")
    fi

    # --- Template Selection ---
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
            log "Downloading ${selected_template_file} to '${template_storage}'..."
            pveam download "${template_storage}" "${selected_template_file}" || fail "Template download failed."
            os_template="${template_storage}:vztmpl/${selected_template_file}"
            ;;
    esac
    log "Using template: ${os_template}"

    # --- Create, Configure, and Start ---
    # This block has the CORRECT --rootfs syntax for ZFS
    log "Creating LXC container '${hostname}' (ID: ${ctid})..."
    pct create "${ctid}" "${os_template}" --hostname "${hostname}" --password "${password}" \
        --memory "${memory}" --cores "${cores}" --net0 name=eth0,bridge=vmbr0,ip=dhcp \
        --storage "${rootfs_storage}" --rootfs "${rootfs_storage}:${rootfs_size}" --onboot 1 --start 0 || fail "pct create failed." 

    log "Configuring LXC for Docker-readiness..."
    pct set ${ctid} --features nesting=1,keyctl=1
    pct set ${ctid} --nameserver 8.8.8.8
    
    log "Starting container..."
    pct start ${ctid}
    log "Pausing for 5 seconds to allow container to settle..."
    sleep 5
    
    log "Waiting for network to become fully operational..."
    local attempts=0
    while ! pct exec "${ctid}" -- ping -c 1 -W 2 8.8.8.8 &>/dev/null; do
        ((attempts++)); if [ "$attempts" -ge 15 ]; then fail "Network did not come online."; fi; sleep 2
    done
    log "Network is online. Provisioning complete."

    # --- Handoff to Phase 2 ---
    log "Handing off to configuration script..."
    local gh_user=$(echo "$1" | grep -oP '(?<=github.com/)[^/]+')
    local gh_repo=$(echo "$1" | grep -oP "(?<=${gh_user}/)[^/]+")
    local config_url="https://raw.githubusercontent.com/${gh_user}/${gh_repo}/main/configure-lxc.sh"
    
    pct exec ${ctid} -- bash -c "wget -qO /tmp/configure.sh ${config_url} && bash /tmp/configure.sh" || fail "Phase 2 configuration script failed."

    log "All phases complete."
}

# The first argument to the script is the launcher URL, passed from launcher.sh
if [ -z "$1" ]; then
    fail "This script must be executed by launcher.sh, not run directly."
fi
main "$1"
