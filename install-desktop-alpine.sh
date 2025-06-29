#!/bin/sh
set -e
echo "--- Running Alpine Desktop Installer ---"
echo "--> Installing Docker..."
apk update >/dev/null
apk add docker docker-compose >/dev/null
rc-update add docker boot
service docker start
echo "--> Docker installed and started."
echo "--> Deploying LXDE Desktop..."
# The lxde-desktop is ubuntu-based, so for a pure Alpine setup, another image would be better,
# but for this test, we are just proving the installation method works.
docker run -d -p 6080:80 --name=lxde-desktop --security-opt apparmor=unconfined dorowu/ubuntu-desktop-lxde-vnc
echo "--- Alpine Desktop Setup Complete ---"
IP_ADDRESS=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
echo "Access at: http://${IP_ADDRESS}:6080"
