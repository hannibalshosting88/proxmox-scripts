#!/bin/sh
set -e
export DEBIAN_FRONTEND=noninteractive

# --- Helper Functions ---
log() {
    # POSIX-compliant color codes
    GREEN='\033[0;32m'
    NC='\033[0m' # No Color
    printf "${GREEN}[INFO]${NC} ===> %s\n" "$1" >&2
}

fail() {
    RED='\033[0;31m'
    NC='\033[0m' # No Color
    printf "${RED}[FAIL]${NC} ==> %s\n" "$1" >&2
    exit 1
}

run_with_spinner() {
    _message=$1; shift
    _command="$@"
    _spinner_chars="/-\|"
    _i=1

    # Start the spinner in the background
    (
        while true; do
            _char=$(expr substr "$_spinner_chars" $_i 1)
            # POSIX-compliant color codes for spinner
            YELLOW='\033[1;33m'
            NC='\033[0m'
            printf "${YELLOW}[WORKING]${NC} %s %s\r" "$_char" "$_message" >&2
            _i=$((_i + 1))
            if [ $_i -gt $(expr length "$_spinner_chars") ]; then
                _i=1
            fi
            sleep 0.1
        done
    ) &
    _spinner_pid=$!

    # Run the actual command, redirecting its output to a temp file
    _temp_log=$(mktemp)
    if ! sh -c "$_command" >"$_temp_log" 2>&1; then
        kill $_spinner_pid
        # Clear the spinner line before printing error
        printf "\033[2K\r" >&2
        fail "Task '$_message' failed. Log:\n$(cat "$_temp_log")"
        rm -f "$_temp_log"
    fi

    # Stop the spinner and clean up
    kill $_spinner_pid
    wait $_spinner_pid 2>/dev/null || true # Suppress "Terminated" message
    rm -f "$_temp_log"

    # Clear the spinner line and print the final "complete" message
    printf "\033[2K\r" >&2
    log "Task '$_message' complete."
}

# --- Task-Specific Functions for Spinner ---

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
run_with_spinner "Installing Docker Engine" "apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
run_with_spinner "Deploying LXDE Desktop" "docker run -d -p 6080:80 --name=lxde-desktop --security-opt apparmor=unconfined dorowu/ubuntu-desktop-lxde-vnc"

log "Debian/Ubuntu Desktop Setup Complete"
IP_ADDRESS=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
echo "Access at: http://${IP_ADDRESS}:6080"