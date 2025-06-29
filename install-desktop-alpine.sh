
#!/bin/sh
set -e

# This function provides clear, structured logging.
run_task() {
    echo "\n---> BEGIN: $1"
    # Run the command, allowing its output to be seen.
    shift
    "$@"
    echo "---> END: $1 (SUCCESS)"
}

# --- Main Execution ---
echo "\n*** Starting Alpine Desktop Installation ***"

run_task "Install Docker" apk update && apk add docker docker-compose
run_task "Enable and start Docker service" rc-update add docker boot && service docker start

# Deploy Webtop (XFCE flavor)
# We use an Alpine-native image for a clean setup.
# See https://docs.linuxserver.io/images/docker-webtop for more tags/options
run_task "Deploy Webtop Desktop Container" docker run -d \
  --name=webtop-desktop \
  -p 3000:3000 \
  -e PUID=1000 \
  -e PGID=1000 \
  -e TZ=Etc/UTC \
  --shm-size="1gb" \
  --restart unless-stopped \
  linuxserver/webtop:alpine-xfce

echo "\n*** Alpine Desktop Setup Complete ***"
IP_ADDRESS=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
echo "Access at: http://${IP_ADDRESS}:3000"