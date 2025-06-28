#!/bin/sh
#
# Phase 2: Configuration script for a basic Web Desktop.
# Version: 8 (Universal Shell)
# - Uses /bin/sh for maximum OS compatibility.

set -e

# --- Self-Contained Spinner Function (sh compatible) ---
run_with_spinner() {
    message=$1; shift
    command_to_run="$@"
    spinner_chars="/-\|"
    
    echo "--> ${message}"
    
    temp_log=$(mktemp)
    # Execute the command string with 'sh -c'
    sh -c "$command_to_run" &> "$temp_log" &
    pid=$!
    
    while kill -0 $pid 2>/dev/null; do
        i=0
        while [ $i -lt ${#spinner_chars} ]; do
            char_to_print=$(echo "$spinner_chars" | cut -c $((i+1)))
            echo -ne "[WORKING] ${char_to_print} \r"
            sleep 0.1
            i=$((i+1))
        done
    done
    
    echo -ne "             \r"
    
    exit_code=0
    wait $pid || exit_code=$?
    
    if [ $exit_code -ne 0 ]; then
        echo "[FAIL] Task '${message}' failed. Log:"
        cat "$temp_log"
        rm -f "$temp_log"
        exit 1
    fi
    rm -f "$temp_log"
    echo "--> Task '${message}' complete."
}


# --- Main Execution ---
echo "--- Phase 2: Installing Software (OS-Aware) ---"

# --- OS Detection & Package Manager Setup ---
echo "--> Detecting operating system..."
if command -v apt-get >/dev/null 2>&1; then
    OS_FAMILY="debian"
    PKG_UPDATE="apt-get update"
    PKG_INSTALL="apt-get install -y"
    echo "--> Detected Debian/Ubuntu based system."
elif command -v apk >/dev/null 2>&1; then
    OS_FAMILY="alpine"
    PKG_UPDATE="apk update"
    PKG_INSTALL="apk add"
    echo "--> Detected Alpine Linux."
else
    echo "ERROR: Unsupported operating system." >&2
    exit 1
fi

# --- Main Installation Logic ---
run_with_spinner "Updating package lists and installing curl" \
    "$PKG_UPDATE && $PKG_INSTALL curl"

case $OS_FAMILY in
    debian)
        run_with_spinner "Generating locale" \
            "apt-get install -y locales && locale-gen en_US.UTF-8"
        ;;
    alpine)
        echo "--> Skipping locale generation for Alpine."
        ;;
esac

echo "--> Installing Docker..."
case $OS_FAMILY in
    debian)
        run_with_spinner "Installing Docker via get.docker.com script" \
            "curl -fsSL https://get.docker.com | sh"
        ;;
    alpine)
        run_with_spinner "Installing Docker via apk" \
            "apk add docker docker-compose"
        # On Alpine, we also need to start and enable the service
        rc-update add docker boot
        service docker start
        ;;
esac
echo "--> Docker installed successfully."

# --- Application Deployment ---
echo "--> Deploying LXDE Desktop container..."
run_with_spinner "Pulling LXDE Desktop image" \
    "docker pull dorowu/ubuntu-desktop-lxde-vnc"

docker run -d -p 6080:80 --name=lxde-desktop --security-opt apparmor=unconfined dorowu/ubuntu-desktop-lxde-vnc
echo "--> Desktop container deployed."

echo ""
echo "--- Configuration Complete ---"
IP_ADDRESS=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
echo "The Web Desktop is accessible at: http://${IP_ADDRESS}:6080"
