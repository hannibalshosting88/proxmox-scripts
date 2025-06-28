#!/bin/bash
# Generic Script Launcher (v31 - Final)

set -e

# --- Configuration ---
GH_USER="hannibalshosting88"
GH_REPO="proxmox-scripts"
TARGET_SCRIPT="provision-lxc.sh"

# --- Execution ---
CACHE_BUSTER="?$(date +%s)"
DOWNLOAD_URL="https://raw.githubusercontent.com/${GH_USER}/${GH_REPO}/main/${TARGET_SCRIPT}${CACHE_BUSTER}"
LOCAL_PATH="/tmp/${TARGET_SCRIPT}"

echo "--> Launcher engaged. Target: ${TARGET_SCRIPT}"
if wget -O "${LOCAL_PATH}" "${DOWNLOAD_URL}"; then
    chmod +x "${LOCAL_PATH}"
    echo "--> Executing main script..."
    echo "----------------------------------------------------"
    # Execute with a dummy argument to satisfy the script's internal check
    "${LOCAL_PATH}" "launched"
else
    echo "!!! CRITICAL: Failed to download '${TARGET_SCRIPT}' from GitHub." >&2
    exit 1
fi
