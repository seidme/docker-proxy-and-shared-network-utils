#!/bin/bash

# A simple script to start all Docker Compose stacks in a specific order.

# Exit immediately if a command exits with a non-zero status.
set -e

# Define the paths to your Docker Compose projects
PROXY_PATH="/var/www/proxy"
SCOUT_PATH="/var/www/scout"
FLXNG_PATH="/var/www/flxng"
VIDEO_DOWNLOADER_PATH="/var/www/video-downloader"

# First stop all the apps in case they are running
echo "Stopping all running stacks..."

if [ -d "$VIDEO_DOWNLOADER_PATH" ]; then
  cd "$VIDEO_DOWNLOADER_PATH" && docker compose down
fi
cd "$FLXNG_PATH" && docker compose down
cd "$SCOUT_PATH" && docker compose down
cd "$PROXY_PATH" && docker compose down 
echo "All stacks stopped."

echo " "
echo "Starting Docker Compose stacks..."

# Step 1: Start the proxy stack first to ensure the network is created.
echo "Starting proxy stack..."
cd "$PROXY_PATH"
# docker compose pull # Optional: Pull latest images before starting
docker compose up -d

# Step 2: Start the scout application stack (piker-api, piker-web, emo-api, postgresdb, browser-service).
echo "Starting scout application stack..."
cd "$SCOUT_PATH"
# docker compose pull # Optional: Pull latest images before starting
docker compose up -d

# Step 3: Start the flxng application stack.
echo "Starting flxng application stack..."
cd "$FLXNG_PATH"
# docker compose pull # Optional: Pull latest images before starting
docker compose up -d

# Step 4: Start the video-downloader application stack.
if [ -d "$VIDEO_DOWNLOADER_PATH" ]; then
  echo "Starting video-downloader application stack..."
  cd "$VIDEO_DOWNLOADER_PATH"
  docker compose up -d
fi

echo "All stacks started successfully!"
