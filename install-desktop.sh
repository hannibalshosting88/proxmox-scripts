#!/bin/bash
#
# Phase 2: Configuration script for a basic Web Desktop.
# Version: 5 (Polished UX with Spinners)

set -e

# --- Self-Contained Spinner Function ---
run_with_spinner() {
    local message=$1; shift
    local command_to_run=("$@")
    local spinner_chars="/-\|"
    
    # Use standard echo with color codes for this script
    echo -e "\e[32m--> \e[0m${message}"
    
    # Run the command in the background, redirecting its output to a log
    local temp_log=$(mktemp)
    "${command_to_run[@]}" &> "$temp_log" &
    local pid=$!
    
    # Display spinner while the command is running
    while kill -0 $pid 2>/dev/null; do
        for (( i=0; i<${#spinner_chars}; i++ )); do
            echo -ne "\e[1;33m[WORKING]\e[0m ${spinner_chars:$i:1} \r"
            sleep 0.1
        done
    done
    
    # Erase the spinner line
    echo -ne "\033[2K\r"
    
    local exit_code=0
    wait $pid || exit_code=$?
    
    if [ $exit_code -ne 0 ]; then
        echo -e "\e[31m[FAIL]\e[0m Task '${message}' failed. See details below:"
        # Print the log from the failed command
        cat "$temp_log"
        rm -f "$temp_log"
        exit 1
    fi
    rm -f "$temp_log"
    echo -e "\e[32m--> \e[0mTask '${message}' complete."
}

# --- Main Execution ---
echo "--- Phase 2: Installing Software (with spinners) ---"

# The IP address is passed as the first argument from the provisioner
IP_ADDRESS=$1

run_with_spinner "Generating locale to fix warnings" \
    bash -c "apt-get update >/dev/null && apt-get install -y locales >/dev/null && locale-gen en_US.UTF-8 >/dev/null"

run_with_spinner "Installing Docker" \
    curl -fsSL https://get.docker.com | sh

run_with_spinner "Pulling LXDE Desktop image (this may take a while)" \
    docker pull dorowu/ubuntu-desktop-lxde-vnc

echo "--> Deploying LXDE Desktop container..."
# The run command is instant, but the pull above is slow. No spinner needed here.
docker run -d -p 6080:80 --name=lxde-desktop --security-opt apparmor=unconfined dorowu/ubuntu-desktop-lxde-vnc
echo "--> Desktop container deployed."


echo ""
echo "--- Configuration Complete ---"
echo "The Web Desktop is accessible at: http://${IP_ADDRESS}:6080"
