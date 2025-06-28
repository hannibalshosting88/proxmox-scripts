#!/bin/bash
#
# All-in-One Proxmox LXC Provisioning Script
# Version: 1.0 (Release)
# This script is self-contained to avoid all caching issues.

# --- Global Settings ---
set -Eeuo pipefail
# The main() function will log to a file, but we need to see early errors.
exec 2> >(tee -a "/tmp/lxc_provisioner_launcher.log")

# --- Helper Functions ---
# We define these early so the main script can use them.
log() { echo -e "\e[32m[INFO]\e[0m ===> $1" >&2; }
warn() { echo -e "\e[33m[WARN]\e[0m ==> $1" >&2; }
fail() {
    echo -e "\e[31m[FAIL]\e[0m ==> $1" >&2
    echo -e "\e[31m[FAIL]\e[0m An unrecoverable error occurred. See launcher log for details." >&2
    exit 1
}

run_with_spinner() {
    local message=$1; shift
    local command_to_run=("$@")
    local spinner_chars="/-\|"
    echo -ne "\e[1;33m[WORKING]\e[0m ${message} " >&2
    local temp_log=$(mktemp)
    "${command_to_run[@]}" &> "$temp_log" &
    local pid=$!
    while kill -0 $pid 2>/dev/null; do for c in ${spinner_chars}; do echo -ne "\e[1;33m${c}\e[0m\r\e[1;33m[WORKING]\e[0m ${message} " >&2; sleep 0.1; done; done
    echo -ne "\033[2K\r" >&2
    local exit_code=0
    wait $pid || exit_code=$?
    if [ $exit_code -ne 0 ]; then fail "Task '${message}' failed. Log:\n$(cat $temp_log)"; fi
    rm -f "$temp_log"
    log "Task '${message}' complete."
}

find_next_id() {
    log "Searching for the first available LXC/VM ID..."
    local id=100
    while pct status "$id" &>/dev/null || qm status "$id" &>/dev/null; do ((id++)); done
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

# --- Main Provisioning Logic ---
provision() {
    # This function is the entire 'provision-lxc.sh' script
    LOG_FILE="/tmp/lxc-provisioning-$(date +%F-%H%M%S).log"
    exec &> >(tee -a "${LOG_FILE}") # Redirect all output from here to the main log
    PS3=$'\n\t> '

    trap 'fail "Script interrupted."' SIGINT SIGTERM
    log "Starting Generic LXC Provisioning (All-in-One)..."

    # --- Configuration ---
    local ctid=$(find_next_id)
    local hostname; while true; do read -p "--> Enter hostname [linux-lxc]: " hostname < /dev/tty; hostname=${hostname:-"linux-lxc"}; if [[ "$hostname" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,61}[a-zA-Z0-9]$ ]]; then break; else warn "Invalid hostname."; fi; done
    local password; while true; do read -s -p "--> Enter root password: " password < /dev/tty; echo; if [[ -n "$password" ]]; then break; else warn "Password cannot be empty."; fi; done
    read -p "--> Enter RAM (MB) [2048]: " memory < /dev/tty; memory=${memory:-2048}
    read -p "--> Enter Cores [2]: " cores < /dev/tty; cores=${cores:-2}
    read -p "--> Enter Disk Size (GB) [10]: " rootfs_size < /dev/tty; rootfs_size=${rootfs_size:-10}

    mapfile -t root_storage_pools < <(pvesm status --content rootdir | awk 'NR>1 {print $1}')
    local rootfs_storage; if [[ ${#root_storage_pools[@]} -eq 1 ]]; then rootfs_storage=${root_storage_pools[0]}; log "Auto-selected disk storage: ${rootfs_storage}"; else rootfs_storage=$(prompt_for_selection "Select storage for the Container Disk:" "${root_storage_pools[@]}"); fi
    mapfile -t tmpl_storage_pools < <(pvesm status --content vztmpl | awk 'NR>1 {print $1}')
    local template_storage; if [[ ${#tmpl_storage_pools[@]} -eq 1 ]]; then template_storage=${tmpl_storage_pools[0]}; log "Auto-selected template storage: ${template_storage}"; else template_storage=$(prompt_for_selection "Select storage for Templates:" "${tmpl_storage_pools[@]}"); fi

    local os_template
    local template_source=$(prompt_for_selection "Use a local template or download a new one?" "Use an existing local template" "Download a new template")
    case $template_source in
        "Use an existing local template")
            mapfile -t local_templates < <(pvesm list "${template_storage}" --content vztmpl | awk 'NR>1 {print $1}')
            if [[ ${#local_templates[@]} -eq 0 ]]; then fail "No local templates found."; fi
            os_template=$(prompt_for_selection "Select a local template:" "${local_templates[@]}")
            ;;
        "Download a new template")
            mapfile -t remote_templates < <(pveam available --section system | awk 'NR>1 {print $2}')
            local selected_template_file=$(prompt_for_selection "Select a template to download:" "${remote_templates[@]}")
            run_with_spinner "Downloading ${selected_template_file}" pveam download "${template_storage}" "${selected_template_file}"
            os_template="${template_storage}:vztmpl/${selected_template_file}"
            ;;
    esac
    
    log "Using template: ${os_template}"
    run_with_spinner "Creating LXC container '${hostname}' (ID: ${ctid})" pct create "${ctid}" "${os_template}" --hostname "${hostname}" --password "${password}" --memory "${memory}" --cores "${cores}" --net0 name=eth0,bridge=vmbr0,ip=dhcp --storage "${rootfs_storage}" --rootfs "${rootfs_storage}:${rootfs_size}" --onboot 1 --start 0

    run_with_spinner "Configuring LXC" pct set ${ctid} --features nesting=1,keyctl=1 --nameserver 8.8.8.8
    run_with_spinner "Starting container" pct start ${ctid}
    
    sleep 2
    run_with_spinner "Waiting for network" pct exec "${ctid}" -- sh -c "until sh -c 'echo > /dev/tcp/8.8.8.8/53' &>/dev/null; do sleep 1; done"

    local os_family="debian"; if echo "${os_template}" | grep -q "alpine"; then os_family="alpine"; fi
    local prime_cmd; if [[ "$os_family" == "alpine" ]]; then prime_cmd="apk update && apk add curl"; else prime_cmd="apt-get update && apt-get install -y curl"; fi
    run_with_spinner "Priming container with curl" pct exec ${ctid} -- sh -c "$prime_cmd"
    
    local container_ip=$(pct exec ${ctid} -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    local gh_user="hannibalshosting88"; local gh_repo="proxmox-scripts"
    echo
    log "SUCCESS: PROVISIONING COMPLETE."
    log "Container '${hostname}' (ID: ${ctid}) is running at IP: ${container_ip}"
    echo
    log "To install the Web Desktop, run this command:"
    echo -e "\e[1;33mpct exec ${ctid} -- sh -c \"curl -sL https://raw.githubusercontent.com/${gh_user}/${gh_repo}/main/install-desktop.sh | sh\"\e[0m"
    echo
}

# --- Launcher Execution ---
echo "--> All-in-One Launcher engaged..."
echo "----------------------------------------------------"
provision
