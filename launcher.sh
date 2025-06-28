#!/bin/bash
# Generic Script Launcher (v28 - Final)
#
# This script is a universal launcher for any script in this repository.
# It solves the 'curl | bash' interactivity problem and expects the name
# of the target script to be passed as an argument.
#
# Usage:
# curl -sL <URL_to_this_script> | bash -s <name_of_script_to_run.sh>

set -e

# --- Configuration ---
GH_USER="hannibalshosting88"
GH_REPO="proxmox-scripts"

# The script to run is now taken from the first argument ($1).
# We add an error check to make sure an argument was provided.
if [ -z "$1" ]; then
    echo "ERROR: You must specify which script to run." >&2
    echo "Usage: curl ... | bash -s <script_name.sh>" >&2
    exit 1
fi
MAIN_SCRIPT_NAME="$1"

# --- Execution ---
DOWNLOAD_URL="https://raw.githubusercontent.com/${GH_USER}/${GH_REPO}/main/${MAIN_SCRIPT_NAME}"
LOCAL_PATH="/tmp/${MAIN_SCRIPT_NAME}"
# We still need this launcher's own URL to pass to the main script for the handoff.
LAUNCHER_URL="https://raw.githubusercontent.com/${GH_USER}/${GH_REPO}/main/launcher.sh"

echo "--> Launcher engaged. Target script: ${MAIN_SCRIPT_NAME}"
echo "--> Downloading main script from ${DOWNLOAD_URL}..."
if wget -O "${LOCAL_PATH}" "${DOWNLOAD_URL}"; then
    chmod +x "${LOCAL_PATH}"
    echo "--> Executing main script..."
    echo "----------------------------------------------------"
    # Execute the main script, passing this launcher's URL as an argument
    # so it can dynamically find other scripts in the repo.
    "${LOCAL_PATH}" "${LAUNCHER_URL}"
else
    echo "!!! CRITICAL: Failed to download '${MAIN_SCRIPT_NAME}' from GitHub." >&2
    exit 1
fi
