#!/bin/bash

set -euo pipefail

# === Colors ===
GREEN="\033[1;32m"
RED="\033[1;31m"
NC="\033[0m"

# === Helper Functions ===
log() {
  echo -e "${GREEN}[INFO] $1${NC}"
}
err() {
  echo -e "${RED}[ERROR] $1${NC}" >&2
}
request_param() {
  read -p "$1: " param
  echo "$param"
}

# === User Input ===
echo "Please enter the following parameters for node setup:"
RPC_URL=$(request_param "Enter the RPC URL")
read -s -p "Enter your private key (will be hidden): " PRIVATE_KEY
echo
if [[ "$PRIVATE_KEY" != 0x* ]]; then
    log "Private key doesn't start with 0x. Adding it..."
    PRIVATE_KEY="0x$PRIVATE_KEY"
fi

log "Final private key starts with: ${PRIVATE_KEY:0:6}..."

# === Constants ===
REGISTRY_ADDRESS=0x3B1554f346DFe5c482Bb4BA31b880c1C18412170
IMAGE="ritualnetwork/infernet-node:1.4.0"
INSTALL_LOG=~/setup_node.log

# === Install Dependencies ===
log "Installing system packages..."
sudo apt update -y
sudo apt install -y snap mc wget curl git htop netcat-openbsd net-tools unzip jq build-essential ncdu tmux make cmake clang pkg-config libssl-dev protobuf-compiler bc lz4 screen

touch $HOME/.bash_profile
cd $HOME

# === Docker Installation ===
if ! command -v docker &>/dev/null; then
    log "Installing Docker..."
    . /etc/*-release
    wget -qO- "https://download.docker.com/linux/${DISTRIB_ID,,}/gpg" | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/${DISTRIB_ID,,} ${DISTRIB_CODENAME} stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt update
    docker_version=$(apt-cache madison docker-ce | grep -oPm1 "(?<=docker-ce | )([^_]+)(?= | https)")
    sudo apt install -y docker-ce="$docker_version" docker-ce-cli="$docker_version" containerd.io
else
    log "Docker already installed."
fi

# === Docker Compose ===
if ! docker compose version &>/dev/null; then
    log "Installing Docker Compose..."
    docker_compose_version=$(wget -qO- https://api.github.com/repos/docker/compose/releases/latest | jq -r ".tag_name")
    sudo wget -O /usr/bin/docker-compose "https://github.com/docker/compose/releases/download/${docker_compose_version}/docker-compose-$(uname -s)-$(uname -m)"
    sudo chmod +x /usr/bin/docker-compose
else
    log "Docker Compose already installed."
fi

# === Clone Infernet ===
cd $HOME
if [ ! -d infernet-container-starter ]; then
    log "Cloning Infernet starter repo..."
    git clone https://github.com/ritual-net/infernet-container-starter
fi
cd infernet-container-starter
cp -f projects/hello-world/container/config.json deploy/config.json

# === Update Config ===
update_json_field() {
    sed -i 's|"'$2'": "[^"]*"|"'$2'": "'$3'"|' "$1"
}
for FILE in deploy/config.json projects/hello-world/container/config.json; do
    update_json_field "$FILE" "rpc_url" "$RPC_URL"
    update_json_field "$FILE" "private_key" "$PRIVATE_KEY"
    update_json_field "$FILE" "registry_address" "$REGISTRY_ADDRESS"
    update_json_field "$FILE" "sleep" 3
    update_json_field "$FILE" "batch_size" 800
    update_json_field "$FILE" "trail_head_blocks" 3
    update_json_field "$FILE" "sync_period" 30
    update_json_field "$FILE" "starting_sub_id" 160000
done

sed -i 's|address registry = .*|address registry = '$REGISTRY_ADDRESS';|' "projects/hello-world/contracts/script/Deploy.s.sol"
sed -i 's|sender := .*|sender := '$PRIVATE_KEY'|' projects/hello-world/contracts/Makefile
sed -i 's|RPC_URL := .*|RPC_URL := '$RPC_URL'|' projects/hello-world/contracts/Makefile

# === Adjust docker-compose ===
sed -i 's|ritualnetwork/infernet-node:.*|ritualnetwork/infernet-node:1.4.0|' deploy/docker-compose.yaml
sed -i 's|0.0.0.0:4000:4000|0.0.0.0:4321:4000|' deploy/docker-compose.yaml
sed -i 's|8545:3000|8845:3000|' deploy/docker-compose.yaml
sed -i 's|container_name: infernet-anvil|container_name: infernet-anvil\n    restart: on-failure|' deploy/docker-compose.yaml

log "Starting containers..."
docker compose -f deploy/docker-compose.yaml up -d

# === Foundry ===
log "Installing Foundry..."
mkdir -p ~/foundry && cd ~/foundry
curl -L https://foundry.paradigm.xyz | bash
source ~/.bashrc

# === Fix Forge Conflicts ===
if [ -f "/usr/bin/forge" ]; then
    sudo rm -f /usr/bin/forge
fi
export PATH="$HOME/.foundry/bin:$PATH"
echo 'export PATH="$HOME/.foundry/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc

log "Updating Foundry..."
pgrep -x anvil &>/dev/null && pkill -x anvil && sleep 2
foundryup

# === Install Contract Deps ===
cd ~/infernet-container-starter/projects/hello-world/contracts/lib
rm -rf forge-std infernet-sdk
forge install --no-commit foundry-rs/forge-std
forge install --no-commit ritual-net/infernet-sdk

# === Deploy Contract ===
cd ~/infernet-container-starter
project=hello-world make deploy-contracts > logs.txt
CONTRACT_ADDRESS=$(grep "Deployed SaysHello" logs.txt | awk '{print $NF}')
rm -f logs.txt

if [ -z "$CONTRACT_ADDRESS" ]; then
    err "Could not extract contract address."
    exit 1
fi

log "Contract deployed at $CONTRACT_ADDRESS"
sed -i 's|0x13D69Cf7d6CE4218F646B759Dcf334D82c023d8e|'$CONTRACT_ADDRESS'|' "projects/hello-world/contracts/script/CallContract.s.sol"

# === Call Contract ===
project=hello-world make call-contract

# === Final docker-compose Setup ===
cd deploy
docker compose down
rm -f docker-compose.yaml
cat > docker-compose.yaml <<EOF
services:
  node:
    image: $IMAGE
    ports:
      - "0.0.0.0:4321:4000"
    volumes:
      - ./config.json:/app/config.json
      - node-logs:/logs
      - /var/run/docker.sock:/var/run/docker.sock
    tty: true
    networks:
      - network
    depends_on:
      - redis
    restart: on-failure
    extra_hosts:
      - "host.docker.internal:host-gateway"
    stop_grace_period: 1m
    container_name: infernet-node

  redis:
    image: redis:7.4.0
    networks:
      - network
    volumes:
      - ./redis.conf:/usr/local/etc/redis/redis.conf
      - redis-data:/data
    restart: on-failure
    expose:
      - "6379"

  fluentbit:
    image: fluent/fluent-bit:3.1.4
    expose:
      - "24224"
    environment:
      - FLUENTBIT_CONFIG_PATH=/fluent-bit/etc/fluent-bit.conf
    volumes:
      - ./fluent-bit.conf:/fluent-bit/etc/fluent-bit.conf
      - /var/log:/var/log:ro
    networks:
      - network
    restart: on-failure

networks:
  network:

volumes:
  node-logs:
  redis-data:
EOF

log "docker-compose.yml regenerated. Starting final containers..."
docker compose up -d

# Clean old container if exists
docker rm -fv infernet-anvil &>/dev/null || true

log "Setup complete."
exit 0
