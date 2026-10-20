#!/usr/bin/env bash
# Prepares a fresh Ubuntu/Debian VM to host Discordy self-hosted GitHub runners (scripts/runner.sh --host).
# Installs Docker Engine from Docker's apt repository, adds the SSH user to the docker group and sets
# a log size limit. Idempotent. Usage: scripts/runner-vm-bootstrap.sh user@vm
# Afterwards: scripts/runner.sh up --host user@vm --count 3 && scripts/runner.sh use vm-<host>
set -euo pipefail
HOST="${1:?usage: $0 user@vm}"
ssh "$HOST" 'bash -s' <<'REMOTE'
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
echo "Re-login may be needed for the docker group. Next: scripts/runner.sh up --host $HOST"
