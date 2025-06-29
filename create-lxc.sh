# ==============================================================================
# FILENAME: provision-lxc.sh
# VERSION: 2.1 (Production Release)
# ==============================================================================
#!/bin/bash

# --- Global Settings ---
set -Eeuo pipefail
LOG_FILE="/tmp/lxc-provisioning-$(date +%F-%H%M%S).log"
exec 3>&2
exec 2> >(tee -a "${LOG_FILE}")

# --- Helper Functions ---
log() { echo -e "\e[32m[INFO]\e[0m ===> $1" >&3; }
warn() { echo -e "\e[33m[WARN]\e[0m ==> $1" >&3; }
fail() {
    echo -e "\e[31m[FAIL]\e[0m ==> $1" >&3
    echo -e "\e[31m[FAIL]\e[0m An unrecoverable error occurred. See log: ${LOG_FILE}" >&3
    exit 1
}

run_with_spinner() {
    local message=$1; shift
    local command_to_run=("$@")
    local spinner_chars="/-\|"
    
    echo -ne "\e[1;33m[WORKING]\e[0m ${message} " >&3
    
    local temp_log=$(mktemp)
    "${command_to_run[@]}" &> "$temp_log" &
    local pid=$!
    
    while kill -0 $pid 2>/dev/null; do
        for (( i=0; i<${#spinner_chars}; i++ )); do
            printf "\e[1;33m%s\e[0m\r\e[1;33m[WORKING]\e[0m %s " "${spinner_chars:$i:1}" "${message}" >&3
            sleep 0.1
        done
    done
    
    echo -ne "\033[2K\r" >&3
    
    local exit_code=0
    wait $pid || exit_code=$?
    
    if [ $exit_code -ne 0 ]; then
        fail "Task '${message}' failed. Log:\n$(cat $temp_log)"
    fi
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
    PS3=$'\n\t> '
    select item in "${options[@]}"; do
        if [[ -n "$item" ]]; then echo "$item"; break; else warn "Invalid selection."; fi
    done < /dev/tty
}

# --- Main Execution ---
main() {
    trap 'fail "Script interrupted."' SIGINT SIGTERM
    log "Starting Generic LXC Provisioning (v2.1)..."

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
    local template_source=$(prompt_for_selection "Use a local template or download one?" "Use local template" "Download new template")
    if [[ "$template_source" == "Use local template" ]]; then
        mapfile -t local_templates < <(pvesm list "${template_storage}" --content vztmpl | awk 'NR>1 {print $1}')
        if [[ ${#local_templates[@]} -eq 0 ]]; then fail "No local templates found."; fi
        os_template=$(prompt_for_selection "Select a local template:" "${local_templates[@]}")
    else
        mapfile -t remote_templates < <(pveam available --section system | awk 'NR>1 {print $2}')
        local selected_template_file=$(prompt_for_selection "Select a template to download:" "${remote_templates[@]}")
        run_with_spinner "Downloading ${selected_template_file}" pveam download "${template_storage}" "${selected_template_file}"; os_template="${template_storage}:vztmpl/${selected_template_file}"
    fi
    
    log "Using template: ${os_template}"
    run_with_spinner "Creating LXC container '${hostname}' (ID: ${ctid})" pct create "${ctid}" "${os_template}" --hostname "${hostname}" --password "${password}" --memory "${memory}" --cores "${cores}" --net0 name=eth0,bridge=vmbr0,ip=dhcp --storage "${rootfs_storage}" --rootfs "${rootfs_storage}:${rootfs_size}" --onboot 1 --start 0

    log "Configuring LXC..."
    # Universal settings for Docker readiness
    pct set ${ctid} --features nesting=1,keyctl=1 --nameserver 8.8.8.8
    
    run_with_spinner "Starting container" pct start ${ctid}
    sleep 2
    run_with_spinner "Waiting for network" pct exec "${ctid}" -- sh -c "until sh -c 'echo > /dev/tcp/8.8.8.8/53' &>/dev/null; do sleep 1; done"

    local os_family="debian"; if echo "${os_template}" | grep -q "alpine"; then os_family="alpine"; fi
    local prime_cmd; if [[ "$os_family" == "alpine" ]]; then prime_cmd="apk update && apk add curl"; else prime_cmd="apt-get update && apt-get install -y curl"; fi
    run_with_spinner "Priming container with curl" pct exec ${ctid} -- sh -c "$prime_cmd"
    
    local container_ip=$(pct exec ${ctid} -- sh -c "ip addr show eth0 | grep 'inet ' | awk '{print \$2}' | cut -d'/' -f1")
    local gh_user="hannibalshosting88"; local gh_repo="proxmox-scripts"
    
    echo >&3; log "SUCCESS: PROVISIONING COMPLETE."
    log "Container '${hostname}' (ID: ${ctid}) is running at IP: ${container_ip}"
    echo >&3; log "Detected OS Family: ${os_family}. Run the appropriate command below:"
    
    if [[ "$os_family" == "alpine" ]]; then
        echo -e "\n\e[1;37m# For your ALPINE container, run:\e[0m" >&3
        echo -e "\e[1;33mpct exec ${ctid} -- sh -c \"curl -sL https://raw.githubusercontent.com/${gh_user}/${gh_repo}/main/install-desktop-alpine.sh | sh\"\e[0m\n" >&3
    else
        echo -e "\n\e[1;37m# For your DEBIAN/UBUNTU container, run:\e[0m" >&3
        echo -e "\e[1;33mpct exec ${ctid} -- sh -c \"curl -sL https://raw.githubusercontent.com/${gh_user}/${gh_repo}/main/install-desktop-debian.sh | sh\"\e[0m\n" >&3
    fi
}
main
#!/bin/bash
#
# Proxmox LXC Provisioning Script
# Version: 2.0 (Production Release)

# --- Global Settings ---
set -Eeuo pipefail
LOG_FILE="/tmp/lxc-provisioning-$(date +%F-%H%M%S).log"
exec 3>&2
exec 2> >(tee -a "${LOG_FILE}")

# --- Helper Functions ---
log() { echo -e "\e[32m[INFO]\e[0m ===> $1" >&3; }
warn() { echo -e "\e[33m[WARN]\e[0m ==> $1" >&3; }
fail() {
    echo -e "\e[31m[FAIL]\e[0m ==> $1" >&3
    echo -e "\e[31m[FAIL]\e[0m An unrecoverable error occurred. See log: ${LOG_FILE}" >&3
    exit 1
}

run_with_spinner() {
    local message=$1; shift
    local command_to_run=("$@")
    local spinner_chars="/-\|"
    
    echo -ne "\e[1;33m[WORKING]\e[0m ${message} " >&3
    
    local temp_log=$(mktemp)
    "${command_to_run[@]}" &> "$temp_log" &
    local pid=$!
    
    while kill -0 $pid 2>/dev/null; do
        for (( i=0; i<${#spinner_chars}; i++ )); do
            printf "\e[1;33m%s\e[0m\r\e[1;33m[WORKING]\e[0m %s " "${spinner_chars:$i:1}" "${message}" >&3
            sleep 0.1
        done
    done
    
    echo -ne "\033[2K\r" >&3
    
    local exit_code=0
    wait $pid || exit_code=$?
    
    if [ $exit_code -ne 0 ]; then
        fail "Task '${message}' failed. Log:\n$(cat $temp_log)"
    fi
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
    PS3=$'\n\t> '
    select item in "${options[@]}"; do
        if [[ -n "$item" ]]; then echo "$item"; break; else warn "Invalid selection."; fi
    done < /dev/tty
}

# --- Main Execution ---
main() {
    trap 'fail "Script interrupted."' SIGINT SIGTERM
    log "Starting Generic LXC Provisioning (v2.0)..."

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
    local template_source=$(prompt_for_selection "Use a local template or download one?" "Use local template" "Download new template")
    if [[ "$template_source" == "Use local template" ]]; then
        mapfile -t local_templates < <(pvesm list "${template_storage}" --content vztmpl | awk 'NR>1 {print $1}')
        if [[ ${#local_templates[@]} -eq 0 ]]; then fail "No local templates found."; fi
        os_template=$(prompt_for_selection "Select a local template:" "${local_templates[@]}")
    else
        mapfile -t remote_templates < <(pveam available --section system | awk 'NR>1 {print $2}')
        local selected_template_file=$(prompt_for_selection "Select a template to download:" "${remote_templates[@]}")
        run_with_spinner "Downloading ${selected_template_file}" pveam download "${template_storage}" "${selected_template_file}"; os_template="${template_storage}:vztmpl/${selected_template_file}"
    fi
    
    log "Using template: ${os_template}"
    run_with_spinner "Creating LXC container '${hostname}' (ID: ${ctid})" pct create "${ctid}" "${os_template}" --hostname "${hostname}" --password "${password}" --memory "${memory}" --cores "${cores}" --net0 name=eth0,bridge=vmbr0,ip=dhcp --storage "${rootfs_storage}" --rootfs "${rootfs_storage}:${rootfs_size}" --onboot 1 --start 0

    local os_family="debian"; if echo "${os_template}" | grep -q "alpine"; then os_family="alpine"; fi
    
    log "Configuring LXC..."
    pct set ${ctid} --features nesting=1,keyctl=1 --nameserver 8.8.8.8
    if [[ "$os_family" == "alpine" ]]; then
        pct set ${ctid} --aa_profile unconfined
        log "Applied unconfined AppArmor profile for Alpine."
    fi
    
    run_with_spinner "Starting container" pct start ${ctid}
    sleep 2
    run_with_spinner "Waiting for network" pct exec "${ctid}" -- sh -c "until sh -c 'echo > /dev/tcp/8.8.8.8/53' &>/dev/null; do sleep 1; done"

    local prime_cmd; if [[ "$os_family" == "alpine" ]]; then prime_cmd="apk update && apk add curl"; else prime_cmd="apt-get update && apt-get install -y curl"; fi
    run_with_spinner "Priming container with curl" pct exec ${ctid} -- sh -c "$prime_cmd"
    
    local container_ip=$(pct exec ${ctid} -- sh -c "ip addr show eth0 | grep 'inet ' | awk '{print \$2}' | cut -d'/' -f1")
    local gh_user="hannibalshosting88"; local gh_repo="proxmox-scripts"
    
    echo >&3; log "SUCCESS: PROVISIONING COMPLETE."
    log "Container '${hostname}' (ID: ${ctid}) is running at IP: ${container_ip}"
    echo >&3; log "Detected OS Family: ${os_family}. Run the appropriate command below:"
    
    if [[ "$os_family" == "alpine" ]]; then
        echo -e "\n\e[1;37m# For your ALPINE container, run:\e[0m" >&3
        echo -e "\e[1;33mpct exec ${ctid} -- sh -c \"curl -sL https://raw.githubusercontent.com/${gh_user}/${gh_repo}/main/install-desktop-alpine.sh | sh\"\e[0m\n" >&3
    else
        echo -e "\n\e[1;37m# For your DEBIAN/UBUNTU container, run:\e[0m" >&3
        echo -e "\e[1;33mpct exec ${ctid} -- sh -c \"curl -sL https://raw.githubusercontent.com/${gh_user}/${gh_repo}/main/install-desktop-debian.sh | sh\"\e[0m\n" >&3
    fi
}

main