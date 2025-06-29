#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

# --- Helper Functions (using bash features) ---
log() {
    echo -e "\e[32m[INFO]\e[0m ===> $1" >&2
}

fail() {
    echo -e "\e[31m[FAIL]\e[0m ==> $1" >&2
    exit 1
}

run_with_spinner() {
    local message=$1; shift
    # The rest of the arguments are the command to run
    local command_to_run=("$@")
    local spinner_chars="/-\|"
    
    # Start spinner in the background
    (
        while true; do
            for (( i=0; i<${#spinner_chars}; i++ )); do
                echo -ne "\e[1;33m[WORKING]\e[0m \e[1;33m${spinner_chars:$i:1}\e[0m ${message}\r" >&2
                sleep 0.1
            done
        done
    ) &
    local spinner_pid=$!

    # Run the actual command, capturing output
    local temp_log
    temp_log=$(mktemp)
    
    # Execute command directly; bash handles functions correctly.
    if ! "${command_to_run[@]}" > "$temp_log" 2>&1; then
        kill "$spinner_pid"
        echo -ne "\033[2K\r" >&2
        fail "Task '${message}' failed. Log:\n$(cat "$temp_log")"
        rm -f "$temp_log"
    fi

    # Stop spinner and clean up
    kill "$spinner_pid"
    wait "$spinner_pid" &>/dev/null
    rm -f "$temp_log"
    
    echo -ne "\033[2K\r" >&2
    log "Task '${message}' complete."
}

# --- Task-Specific Functions ---
configure_locales() {
    if ! command -v locale-gen >/dev/null; then
        apt-get update
        apt-get install -y locales
    fi
    sed -i 's/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen
    locale-gen
    update-locale LANG=en_US.UTF-8
}

setup_docker_repo() {
    apt-get install -y curl apt-transport-https ca-certificates gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update
}

# --- Main Execution ---
log "Starting Debian/Ubuntu Desktop Installer..."

run_with_spinner "Configuring locales" configure_locales
run_with_spinner "Setting up Docker repository" setup_docker_repo
run_with_spinner "Installing Docker Engine" apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
run_with_spinner "Deploying LXDE Desktop" docker run -d -p 6080:80 --name=lxde-desktop --security-opt apparmor=unconfined dorowu/ubuntu-desktop-lxde-vnc

log "Debian/Ubuntu Desktop Setup Complete"
IP_ADDRESS=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
echo "Access at: http://${IP_ADDRESS}:6080"