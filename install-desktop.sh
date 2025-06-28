#!/bin/bash
#
# Phase 2: Configuration script for a basic Web Desktop.
# Version 2: Polished and Corrected.

set -e

# The IP address is passed as the first argument from the provisioner's handoff command
IP_ADDRESS=$1

echo "--- Phase 2: Installing Software ---"

echo "--> Generating locale to fix language warnings..."
apt-get install -y locales >/dev/null
locale-gen en_US.UTF-8 >/dev/null
echo "--> Locale generated."

echo "--> Installing Docker..."
# The get.docker.com script handles its own dependencies like curl
curl -fsSL https://get.docker.com | sh >/dev/null
echo "--> Docker installed successfully."

echo "--> Deploying LXDE Desktop container..."
# Added --security-opt to fix AppArmor error
docker run -d -p 6080:80 --name=lxde-desktop --security-opt apparmor=unconfined dorowu/ubuntu-desktop-lxde-vnc >/dev/null
echo "--> Desktop container deployed."

echo "--- Configuration Complete ---"
echo "Web Desktop is accessible at: http://${IP_ADDRESS}:6080"
