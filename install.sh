#!/bin/bash

# === Helper Functions ===
request_param() {
    read -p "$1: " param
    echo $param
}

check_and_install() {
    if ! command -v $1 &> /dev/null; then
        sudo apt install -y $1
    fi
}

update_json_field() {
    local file=$1
    local key=$2
    local value=$3
    sed -i 's|"'$key'": "[^"]*"|"'$key'": "'$value'"|' "$file"
}

# === User Input ===
echo "Please enter the following parameters for node setup:"
RPC_URL=$(request_param "Enter the RPC URL")
PRIVATE_KEY=$(request_param "Enter your private key (should start with 0x)")

if [[ "$PRIVATE_KEY" != 0x* ]]; then
    echo "Private key doesn't start with 0x. Adding it automatically..."
    PRIVATE_KEY="0x$PRIVATE_KEY"
fi

echo "Final private key captured."

# === Constants ===
REGISTRY_ADDRESS=0x3B1554f346DFe5c482Bb4BA31b880c1C18412170
IMAGE="ritualnetwork/infernet-node:1.4.0"

# === Install Packages ===
echo "Installing dependencies..."
sudo apt update -y
sudo apt install -y snap mc wget curl git htop netcat-openbsd net-tools unzip jq build-essential ncdu tmux make cmake clang pkg-config libssl-dev protobuf-compiler bc lz4 screen

# === Install Docker ===
if ! docker --version &> /dev/null; then
    . /etc/*-release
    curl -fsSL https://download.docker.com/linux/${DISTRIB_ID,,}/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/${DISTRIB_ID,,} ${DISTRIB_CODENAME} stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt update
    sudo apt install -y docker-ce docker-ce-cli containerd.io
fi

# === Install Docker Compose ===
if ! docker compose version &> /dev/null; then
    docker_compose_version=$(wget -qO- https://api.github.com/repos/docker/compose/releases/latest | jq -r ".tag_name")
    sudo wget -O /usr/bin/docker-compose "https://github.com/docker/compose/releases/download/${docker_compose_version}/docker-compose-$(uname -s)-$(uname -m)"
    sudo chmod +x /usr/bin/docker-compose
fi

# === Clone Repo ===
cd $HOME
[ -d infernet-container-starter ] || git clone https://github.com/ritual-net/infernet-container-starter
cd infernet-container-starter
cp projects/hello-world/container/config.json deploy/config.json

# === Update Configs ===
DEPLOY_JSON=deploy/config.json
CONTAINER_JSON=projects/hello-world/container/config.json

for file in "$DEPLOY_JSON" "$CONTAINER_JSON"; do
    update_json_field "$file" "rpc_url" "$RPC_URL"
    update_json_field "$file" "private_key" "$PRIVATE_KEY"
    update_json_field "$file" "registry_address" "$REGISTRY_ADDRESS"
    update_json_field "$file" "sleep" 3
    update_json_field "$file" "batch_size" 800
    update_json_field "$file" "trail_head_blocks" 3
    update_json_field "$file" "sync_period" 30
    update_json_field "$file" "starting_sub_id" 160000
done

# === Patch Deploy Script and Makefile ===
sed -i 's|address registry = .*|address registry = '$REGISTRY_ADDRESS';|' projects/hello-world/contracts/script/Deploy.s.sol
sed -i 's|sender := .*|sender := '$PRIVATE_KEY'|' projects/hello-world/contracts/Makefile
sed -i 's|RPC_URL := .*|RPC_URL := '$RPC_URL'|' projects/hello-world/contracts/Makefile

# === Docker Config Adjustments ===
sed -i 's|ritualnetwork/infernet-node:.*|ritualnetwork/infernet-node:1.4.0|' deploy/docker-compose.yaml
sed -i 's|0.0.0.0:4000:4000|0.0.0.0:4321:4000|' deploy/docker-compose.yaml
sed -i 's|8545:3000|8845:3000|' deploy/docker-compose.yaml

if ! grep -q 'restart:' deploy/docker-compose.yaml; then
  sed -i '/container_name: infernet-anvil/a \    restart: on-failure' deploy/docker-compose.yaml
fi

# === Start Initial Containers ===
docker compose -f deploy/docker-compose.yaml up -d

# === Stop anvil if running (MOVED UP) ===
if pgrep -x "anvil" > /dev/null; then
    pkill -x anvil
    sleep 2
fi

# === Install Foundry ===
cd $HOME && mkdir -p foundry && cd foundry
curl -L https://foundry.paradigm.xyz | bash

export PATH="$HOME/.foundry/bin:$PATH"
echo 'export PATH="$HOME/.foundry/bin:$PATH"' >> ~/.bashrc
echo 'export PATH="$HOME/.foundry/bin:$PATH"' >> ~/.profile
source ~/.bashrc

foundryup

# === Fix Forge Conflicts ===
if [ -f "/usr/bin/forge" ]; then
    sudo rm -f /usr/bin/forge
fi
forge --version

# === Install Contract Dependencies ===
cd $HOME/infernet-container-starter/projects/hello-world/contracts/lib/
rm -rf forge-std infernet-sdk
forge install --no-commit foundry-rs/forge-std
forge install --no-commit ritual-net/infernet-sdk

# === Deploy Contracts ===
cd $HOME/infernet-container-starter
project=hello-world make deploy-contracts >> logs.txt
CONTRACT_ADDRESS=$(grep "Deployed SaysHello" logs.txt | awk '{print $NF}')
rm -f logs.txt

if [ -z "$CONTRACT_ADDRESS" ]; then
  echo "Error: Could not extract contract address."
  exit 1
fi

sed -i 's|0x13D69Cf7d6CE4218F646B759Dcf334D82c023d8e|'$CONTRACT_ADDRESS'|' "projects/hello-world/contracts/script/CallContract.s.sol"

# === Call Contract ===
project=hello-world make call-contract

# === Final Compose Setup ===
cd deploy
docker compose down
sleep 3
rm -f docker-compose.yaml
docker pull ritualnetwork/hello-world-infernet:latest
cat > docker-compose.yml <<EOF
services:
  node:
    image: ritualnetwork/infernet-node:1.4.0
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

echo "docker-compose.yml created. Starting services..."
docker compose up -d

docker rm -fv infernet-anvil &>/dev/null

echo "Node setup complete. Contract deployed at $CONTRACT_ADDRESS"
