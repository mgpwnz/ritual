#!/bin/bash

set -e

# === Stop and remove docker containers ===
echo "Stopping and removing Docker containers..."
docker compose -f $HOME/infernet-container-starter/deploy/docker-compose.yaml down --remove-orphans || true
docker rm -fv infernet-node infernet-redis infernet-fluentbit infernet-anvil 2>/dev/null || true

# === Remove infernet repo ===
echo "Removing infernet-container-starter directory..."
rm -rf $HOME/infernet-container-starter

# === Remove Foundry ===
echo "Removing Foundry installation..."
rm -rf $HOME/.foundry $HOME/foundry

# === Remove docker volumes ===
echo "Removing Docker volumes..."
docker volume rm infernet-container-starter_node-logs infernet-container-starter_redis-data 2>/dev/null || true

# === Optional cleanup ===
echo "Removing other temporary files..."
rm -f $HOME/contract-call.log $HOME/logs.txt

echo "✅ Infernet node and all related components have been removed."
