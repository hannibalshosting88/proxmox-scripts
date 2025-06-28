#!/bin/bash
#
# Phase 2: Configuration Script
# This runs INSIDE the newly created LXC.

set -e

echo "--- Now running Phase 2: Configuration ---"

echo "--> Installing Docker..."
apt-get update >/dev/null
apt-get install -y curl >/dev/null
curl -fsSL https://get.docker.com | sh >/dev/null
echo "--> Docker installed."

echo "--> Deploying LXDE Desktop container..."
docker run -d -p 6080:80 --name=lxde-desktop dorowu/ubuntu-desktop-lxde-vnc >/dev/null
echo "--> Desktop container deployed."

echo "--- Configuration Complete ---"
# Note: Can't easily get the IP from in here, but the main script will have it.
