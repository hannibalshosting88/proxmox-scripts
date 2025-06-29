#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

# This function provides clear, structured, and verbose logging.
run_task() {
    # Announce the start of a task in yellow.
    echo -e "\n\e[1;33m--- BEGIN: $1 ---\e[0m"

    # Run the command, allowing its output to be seen.
    # All arguments after the first one are the command.
    shift
    "$@"

    # Announce the successful completion in green.
    echo -e "\e[32m--- END: $1 (SUCCESS) ---\e[0m"
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
echo -e "\n\e[1;32m*** Starting Debian/Ubuntu Desktop Installation ***\e[0m"

run_task "Configure Locales" configure_locales
run_task "Setup Docker Repository" setup_docker_repo
run_task "Install Docker Engine" apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
run_task "Deploy LXDE Desktop Container" docker run -d -p 6080:80 --name=lxde-desktop --security-opt apparmor=unconfined dorowu/ubuntu-desktop-lxde-vnc

echo -e "\n\e[1;32m*** Debian/Ubuntu Desktop Setup Complete ***\e[0m"
IP_ADDRESS=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
echo "Access at: http://${IP_ADDRESS}:6080"