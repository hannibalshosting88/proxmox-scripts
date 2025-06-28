#!/bin/bash
#
# Phase 2: Configuration script for a basic Web Desktop.
# This runs INSIDE the newly created LXC.

set -e

echo "--- Phase 2: Installing Docker and Web Desktop ---"

echo "--> Updating package lists and installing dependencies..."
apt-get update >/dev/null
apt-get install -y curl >/dev/null

echo "--> Installing Docker..."
curl -fsSL https://get.docker.com | sh >/dev/null
echo "--> Docker installed successfully."

echo "--> Deploying LXDE Desktop container..."
docker run -d -p 6080:80 --name=lxde-desktop --security-opt apparmor=unconfined dorowu/ubuntu-desktop-lxde-vnc
echo "--> Desktop container deployed."

echo "--- Configuration Complete. ---"
echo "You should be able to access the desktop at http://<container_ip>:6080"
