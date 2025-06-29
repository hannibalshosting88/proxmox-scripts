#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

# This function is the core of the fix. It handles output atomically.
run_with_spinner() {
    local message=$1; shift
    local command_to_run=("$@")

    # Define the spinner animation function locally
    spinner() {
        local chars="/-\|"
        while true; do
            for (( i=0; i<${#chars}; i++ )); do
                printf "\e[1;33m[WORKING]\e[0m %s %s\r" "${chars:$i:1}" "$message" >&2
                sleep 0.1
            done
        done
    }

    spinner &
    local spinner_pid=$!

    # Capture the exit code of the command
    local temp_log
    temp_log=$(mktemp)
    "${command_to_run[@]}" >"$temp_log" 2>&1
    local exit_code=$?

    # Stop the spinner cleanly
    kill "$spinner_pid" &>/dev/null
    wait "$spinner_pid" &>/dev/null

    # Atomically clear the line and print the final status
    if [ $exit_code -eq 0 ]; then
        printf "\r\033[2K\e[32m[INFO]\e[0m ===> Task '%s' complete.\n" "$message" >&2
    else
        printf "\r\033[2K\e[31m[FAIL]\e[0m ==> Task '%s' failed. Log:\n" "$message" >&2
        cat "$temp_log" >&2
        rm -f "$temp_log"
        exit 1
    fi
    rm -f "$temp_log"
}

# --- Task-Specific Functions (Unchanged) ---
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
echo -e "\e[32m[INFO]\e[0m ===> Starting Debian/Ubuntu Desktop Installer..."

run_with_spinner "Configuring locales" configure_locales
run_with_spinner "Setting up Docker repository" setup_docker_repo
run_with_spinner "Installing Docker Engine" apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
run_with_spinner "Deploying LXDE Desktop" docker run -d -p 6080:80 --name=lxde-desktop --security-opt apparmor=unconfined dorowu/ubuntu-desktop-lxde-vnc

echo -e "\e[32m[INFO]\e[0m ===> --- Debian/Ubuntu Desktop Setup Complete ---"
IP_ADDRESS=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
echo "Access at: http://${IP_ADDRESS}:6080"