#!/bin/bash
#
# Phase 2: Configuration script for a basic Web Desktop.
# Version: 4 (Self-Sufficient)

set -e

echo "--- Phase 2: Installing Software ---"

echo "--> Generating locale to fix language warnings..."
# Check if locales package is installed, if not, install it.
if ! dpkg -s locales >/dev/null 2>&1; then
    apt-get update >/dev/null
    apt-get install -y locales >/dev/null
fi
locale-gen en_US.UTF-8 >/dev/null
echo "--> Locale generated."

echo "--> Installing Docker..."
curl -fsSL https://get.docker.com | sh >/dev/null
echo "--> Docker installed successfully."

echo "--> Deploying LXDE Desktop container..."
docker run -d -p 6080:80 --name=lxde-desktop --security-opt apparmor=unconfined dorowu/ubuntu-desktop-lxde-vnc
echo "--> Desktop container deployed."

echo "--- Configuration Complete ---"
# MODIFICATION: Find the IP from within the container itself.
IP_ADDRESS=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
echo "The Web Desktop is accessible at: http://${IP_ADDRESS}:6080"
