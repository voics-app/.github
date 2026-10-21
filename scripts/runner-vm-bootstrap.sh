#!/usr/bin/env bash
# Prepares an Ubuntu/Debian VM to host Discordy self-hosted GitHub runners. Installs Docker Engine from
# Docker's apt repository, adds the user to the docker group and sets a log size limit. Idempotent.
#
#   On the VM itself (no argument; run as your normal user, NOT with sudo - it asks for sudo itself):
#     scripts/runner-vm-bootstrap.sh
#   From another machine over SSH (needs your SSH key on the VM: ssh-copy-id user@vm):
#     scripts/runner-vm-bootstrap.sh user@vm
#
# Afterwards, on the VM: scripts/runner.sh up              (label vm-<hostname>, switches CI to it)
#         or remotely:   scripts/runner.sh up --host user@vm
set -euo pipefail
HOST="${1:-}"
[[ $EUID -eq 0 ]] && { echo "Run this as your normal user, not with sudo (it calls sudo itself)."; exit 1; }
SCRIPT="$(mktemp)"
trap 'rm -f "$SCRIPT"' EXIT
cat > "$SCRIPT" <<'REMOTE'
set -euo pipefail
if ! command -v docker >/dev/null; then
  sudo apt-get update -qq
  sudo apt-get install -y -qq ca-certificates curl gnupg
  sudo install -m 0755 -d /etc/apt/keyrings
  . /etc/os-release
  curl -fsSL "https://download.docker.com/linux/${ID}/gpg" | sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin
fi
sudo usermod -aG docker "$USER"
echo '{"log-driver":"json-file","log-opts":{"max-size":"20m","max-file":"3"}}' | sudo tee /etc/docker/daemon.json >/dev/null
sudo systemctl enable --now docker >/dev/null
sudo systemctl restart docker
echo "docker $(docker --version 2>/dev/null || sudo docker --version) ready; cpus=$(nproc) mem=$(free -g | awk '/Mem/{print $2}')G disk_free=$(df -h / | awk 'NR==2{print $4}')"
REMOTE
if [[ -z "$HOST" ]]; then
  bash "$SCRIPT"
else
  # Copy the script and run it with a terminal (-t) so sudo can ask for the password.
  scp -q "$SCRIPT" "$HOST:/tmp/discordy-runner-bootstrap.sh"
  ssh -t "$HOST" 'bash /tmp/discordy-runner-bootstrap.sh; rm -f /tmp/discordy-runner-bootstrap.sh'
fi
echo "Log out and back in (or run: newgrp docker) so the docker group applies. Next: scripts/runner.sh up${HOST:+ --host $HOST}"
