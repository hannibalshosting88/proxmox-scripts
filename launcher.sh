#!/bin/bash
# Generic Script Launcher (v30 - Final w/ Cache Busting)
#
# Usage: curl ... | bash -s <target_script.sh>

set -e

# --- Configuration ---
GH_USER="hannibalshosting88"
GH_REPO="proxmox-scripts"

if [ -z "$1" ]; then
    echo "ERROR: You must specify which script to run." >&2
    echo "Usage: curl ... | bash -s <script_name.sh>" >&2
    exit 1
fi
TARGET_SCRIPT="$1"

# --- Execution ---
# MODIFICATION: Add a cache-busting query string to the download URL
CACHE_BUSTER="?$(date +%s)"
DOWNLOAD_URL="https://raw.githubusercontent.com/${GH_USER}/${GH_REPO}/main/${TARGET_SCRIPT}${CACHE_BUSTER}"
LOCAL_PATH="/tmp/${TARGET_SCRIPT}"
LAUNCHER_URL="https://raw.githubusercontent.com/${GH_USER}/${GH_REPO}/main/launcher.sh"

echo "--> Launcher engaged. Target: ${TARGET_SCRIPT}"
echo "--> Downloading main script from ${DOWNLOAD_URL}..."
if wget -O "${LOCAL_PATH}" "${DOWNLOAD_URL}"; then
    chmod +x "${LOCAL_PATH}"
    echo "--> Executing main script..."
    echo "----------------------------------------------------"
    # Execute the main script, passing this launcher's URL as an argument
    "${LOCAL_PATH}" "${LAUNCHER_URL}"
else
    echo "!!! CRITICAL: Failed to download '${TARGET_SCRIPT}' from GitHub." >&2
    exit 1
fi
