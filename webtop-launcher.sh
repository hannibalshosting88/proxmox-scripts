#!/bin/bash
# webtop-launcher.sh: Downloads and executes the main deployment script.
# This avoids interactivity issues with piped execution.

set -e # Exit immediately if a command exits with a non-zero status.

# --- Configuration ---
# Your GitHub username and repository name.
GH_USER="hannibalshosting88" # <-- EDIT THIS
GH_REPO="proxmox-scripts"  # <-- EDIT THIS
MAIN_SCRIPT_NAME="create-webtop-lxc.sh"
DOWNLOAD_URL="https://raw.githubusercontent.com/${GH_USER}/${GH_REPO}/main/${MAIN_SCRIPT_NAME}"
LOCAL_PATH="/tmp/${MAIN_SCRIPT_NAME}"

# --- Execution ---
echo "--> Downloading main script from ${DOWNLOAD_URL}..."
if wget -O "${LOCAL_PATH}" "${DOWNLOAD_URL}"; then
    echo "--> Download successful. Making script executable..."
    chmod +x "${LOCAL_PATH}"
    echo "--> Executing main script: ${LOCAL_PATH}"
    echo "----------------------------------------------------"
    # Execute the script, passing along any arguments
    "${LOCAL_PATH}" "$@"
else
    echo "!!! CRITICAL: Failed to download main script from GitHub." >&2
    echo "!!! Please check the URL and your network connection." >&2
    exit 1
fi
