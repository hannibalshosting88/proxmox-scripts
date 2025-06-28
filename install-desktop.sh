#!/bin/bash
#
# Phase 2: Universal Configuration Script
# Version: 7 (Multi-OS Support)
# - Detects the OS (Debian/Ubuntu vs. Alpine) and uses the correct package manager.

set -e

echo "--- Phase 2: Installing Software (OS-Aware) ---"

# --- OS Detection & Package Manager Setup ---
echo "--> Detecting operating system..."
if command -v apt-get &>/dev/null; then
    OS_FAMILY="debian"
    PKG_UPDATE="apt-get update"
    PKG_INSTALL="apt-get install -y"
    echo "--> Detected Debian/Ubuntu based system."
elif command -v apk &>/dev/null; then
    OS_FAMILY="alpine"
    PKG_UPDATE="apk update"
    PKG_INSTALL="apk add"
    echo "--> Detected Alpine Linux."
else
    echo "ERROR: Unsupported operating system." >&2
    exit 1
fi

# --- Dependency Installation ---
run_with_spinner() {
    local message=$1; shift; local command_to_run=("$@")
    local spinner_chars="/-\|"
    echo -e "\e[32m--> \e[0m${message}"
    local temp_log=$(mktemp)
    "${command_to_run[@]}" &> "$temp_log" &
    local pid=$!
    while kill -0 $pid 2>/dev/null; do
        for (( i=0; i<${#spinner_chars}; i++ )); do
            echo -ne "\e[1;33m[WORKING]\e[0m ${spinner_chars:$i:1} \r"
            sleep 0.1
        done
    done
    echo -ne "\033[2K\r"
    local exit_code=0
    wait $pid || exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo -e "\e[31m[FAIL]\e[0m Task '${message}' failed. Log:"
        cat "$temp_log"
        rm -f "$temp_log"
        exit 1
    fi
    rm -f "$temp_log"
    echo -e "\e[32m--> \e[0mTask '${message}' complete."
}

# Run updates and install curl using the detected package manager
run_with_spinner "Updating package lists" $PKG_UPDATE
run_with_spinner "Installing curl" $PKG_INSTALL curl

# --- Locale Generation (OS-specific) ---
case $OS_FAMILY in
    debian)
        run_with_spinner "Generating locale" \
            bash -c "apt-get install -y locales >/dev/null && locale-gen en_US.UTF-8 >/dev/null"
        ;;
    alpine)
        # Alpine is minimal and doesn't usually need this. We can add steps here if needed.
        echo "--> Skipping locale generation for Alpine."
        ;;
esac

# --- Docker Installation (OS-specific) ---
echo "--> Installing Docker..."
case $OS_FAMILY in
    debian)
        run_with_spinner "Installing Docker via get.docker.com script" \
            bash -c "curl -fsSL https://get.docker.com | sh"
        ;;
    alpine)
        run_with_spinner "Installing Docker via apk" \
            apk add docker docker-compose
        # On Alpine, we also need to start and enable the service
        rc-update add docker boot
        service docker start
        ;;
esac
echo "--> Docker installed successfully."

# --- Application Deployment (Universal) ---
echo "--> Deploying LXDE Desktop container..."
run_with_spinner "Pulling LXDE Desktop image" \
    docker pull dorowu/ubuntu-desktop-lxde-vnc

docker run -d -p 6080:80 --name=lxde-desktop --security-opt apparmor=unconfined dorowu/ubuntu-desktop-lxde-vnc
echo "--> Desktop container deployed."

echo ""
echo "--- Configuration Complete ---"
IP_ADDRESS=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
echo "The Web Desktop is accessible at: http://${IP_ADDRESS}:6080"
