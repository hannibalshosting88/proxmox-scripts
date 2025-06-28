#!/bin/bash
#
# Proxmox LXC Provisioning Script
# Version: 36 (Parallel Operations)

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

# NEW: Spinner function to show activity for background tasks
run_with_spinner() {
    local command_to_run=("$@")
    local spinner_chars="/-\|"
    
    # Run the command in the background
    "${command_to_run[@]}" &
    local pid=$!
    
    # Display spinner while the command is running
    while kill -0 $pid 2>/dev/null; do
        for (( i=0; i<${#spinner_chars}; i++ )); do
            echo -ne "\e[1;33m[WORKING]\e[0m ${spinner_chars:$i:1} \r" >&2
            sleep 0.1
        done
    done
    
    # Wait for the command to finish and capture its exit code
    local exit_code=0
    wait $pid || exit_code=$?
    
    # Erase the spinner line
    echo -ne "\033[2K\r" >&2

    if [ $exit_code -ne 0 ]; then
        fail "Background task failed with exit code ${exit_code}."
    fi
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
    log "Starting Generic LXC Provisioning (v36)..."

    # --- RE-ORDERED LOGIC FOR PARALLEL OPS ---
    # 1. Get storage info first, as it's needed for downloads.
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

    # 2. Determine template. If downloading, start it in the background.
    local os_template
    local download_started=false
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
            log "Starting download for ${selected_template_file} in the background..."
            # Call the spinner function to run the download
            run_with_spinner pveam download "${template_storage}" "${selected_template_file}"
            download_started=true
            os_template="${template_storage}:vztmpl/${selected_template_file}"
            log "Download complete."
            ;;
    esac
    
    # 3. Get user input for the container details WHILE download runs.
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

    # 4. Create the container. The 'wait' is handled inside run_with_spinner.
    log "Using template: ${os_template}"
    log "Creating LXC container '${hostname}' (ID: ${ctid})..."
    pct create "${ctid}" "${os_template}" --hostname "${hostname}" --password "${password}" \
        --memory "${memory}" --cores "${cores}" --net0 name=eth0,bridge=vmbr0,ip=dhcp \
        --storage "${rootfs_storage}" --rootfs "${rootfs_storage}:${rootfs_size}" --onboot 1 --start 0 || fail "pct create failed."

    # --- The rest of the script continues as before ---
    log "Configuring LXC..."
    pct set ${ctid} --features nesting=1,keyctl=1
    pct set ${ctid} --nameserver 8.8.8.8
    
    log "Starting container..."
    pct start ${ctid}
    
    sleep 5 
    local container_ip=$(pct exec ${ctid} -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "IP_NOT_YET_AVAILABLE")
    echo
    log "SUCCESS: Provisioning complete."
    log "Container '${hostname}' (ID: ${ctid}) is running. IP Address: ${container_ip}"
    echo
    log "Choose a configuration script to run from the options below:"
    
    local gh_user=$(echo "$1" | cut -d/ -f4)
    local gh_repo=$(echo "$1" | cut -d/ -f5)
    
    echo -e "\n\e[1;37m# To install the Web Desktop:\e[0m"
    echo -e "\e[1;33mpct exec ${ctid} -- bash -c \"curl -sL https://raw.githubusercontent.com/${gh_user}/${gh_repo}/main/install-desktop.sh | bash\"\e[0m"
    
    echo
    
    log "Attempting to prime container in the background..."
    local attempts=0
    while ! pct exec "${ctid}" -- ping -c 1 -W 2 8.8.8.8 &>/dev/null; do
        ((attempts++)); if [ "$attempts" -ge 15 ]; then
            warn "Network check timed out. You may need to wait a moment before running the next command."
            exit 0
        fi
        sleep 2
    done

    pct exec ${ctid} -- bash -c "apt-get update &>/dev/null && apt-get install -y curl &>/dev/null" || warn "Could not pre-install curl."
    log "Priming complete."
}

if [ -z "$1" ]; then
    fail "This script must be executed by launcher.sh, not run directly."
fi
main "$1"
