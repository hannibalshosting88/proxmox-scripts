#!/bin/sh
set -e
echo "--- Running Debian/Ubuntu Desktop Installer ---"
echo "--> Installing prerequisites..."
apt-get update >/dev/null
apt-get install -y curl apt-transport-https ca-certificates gnupg >/dev/null
echo "--> Setting up Docker repository..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update >/dev/null
echo "--> Installing Docker Engine..."
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
echo "--> Deploying LXDE Desktop..."
docker run -d -p 6080:80 --name=lxde-desktop --security-opt apparmor=unconfined dorowu/ubuntu-desktop-lxde-vnc
echo "--- Debian/Ubuntu Desktop Setup Complete ---"
IP_ADDRESS=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
echo "Access at: http://${IP_ADDRESS}:6080"
