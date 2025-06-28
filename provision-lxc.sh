#!/bin/bash
#
# Proxmox LXC Provisioning Script
# Version: 35 (Final Architecture)

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
    log "Starting Generic LXC Provisioning (v35)..."

    # --- Configuration with Input Validation ---
    local ctid=$(find_next_id)
    local hostname
    while true; do
        read -p "--> Enter a hostname for the new container [linux-lxc]: " hostname < /dev/tty
        hostname=${hostname:-"linux-lxc"}
        if [[ "$hostname" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,61}[a-zA-Z0-9]$ ]]; then
            break
        else
            warn "Invalid hostname. Use only letters, numbers, and hyphens."
        fi
    done

    local password
    while true; do
        read -s -p "--> Enter a secure root password for the container: " password < /dev/tty; echo
        if [[ -n "$password" ]]; then
            break
        else
            warn "Password cannot be empty. Please try again."
        fi
    done

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

    log "Configuring LXC..."
    pct set ${ctid} --features nesting=1,keyctl=1
    pct set ${ctid} --nameserver 8.8.8.8
    
    log "Starting container..."
    pct start ${ctid}
    
    # --- Final Output (Instructions First) ---
    # Give the container a moment to get an IP before we try to display it.
    sleep 5 
    local container_ip=$(pct exec ${ctid} -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "IP_NOT_YET_AVAILABLE")
    echo
    log "SUCCESS: Provisioning complete."
    log "Container '${hostname}' (ID: ${ctid}) is running. IP Address: ${container_ip}"
    echo
    log "Choose a configuration script to run from the options below:"
    
    local gh_user="hannibalshosting88"
    local gh_repo="proxmox-scripts"
    
    echo -e "\n\e[1;37m# To install the Web Desktop:\e[0m"
    # MODIFICATION: The handoff command is now simpler and more robust.
    echo -e "\e[1;33mpct exec ${ctid} -- bash -c \"curl -sL https://raw.githubusercontent.com/${gh_user}/${gh_repo}/main/install-desktop.sh | bash\"\e[0m"
    
    echo
    
    # --- Best-Effort Finalization ---
    log "Attempting to prime container in the background..."
    local attempts=0
    while ! pct exec "${ctid}" -- ping -c 1 -W 2 8.8.8.8 &>/dev/null; do
        ((attempts++)); if [ "$attempts" -ge 15 ]; then
            warn "Network check timed out. You may need to wait a moment before running the next command."
            exit 0
        fi
        sleep 2
    done

    pct exec ${ctid} -- bash -c "apt-get update >/dev/null && apt-get install -y curl >/dev/null" || warn "Could not pre-install curl."
    log "Priming complete."
}

main "$@"
