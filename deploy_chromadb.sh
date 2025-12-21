#!/bin/bash
# deploy_chromadb.sh
# Complete deployment of ChromaDB on Google Cloud with persistent disk

set -e

# -----------------------------
# 1. Format and mount persistent disk
# -----------------------------
PERSIST_DISK="/dev/sda"
MOUNT_POINT="/data"

echo "Creating mount point..."
sudo mkdir -p $MOUNT_POINT

echo "Formatting persistent disk $PERSIST_DISK..."
sudo mkfs.ext4 -F $PERSIST_DISK

echo "Mounting $PERSIST_DISK to $MOUNT_POINT..."
sudo mount $PERSIST_DISK $MOUNT_POINT

echo "Setting permissions..."
sudo chown $USER:$USER $MOUNT_POINT

echo "Adding to fstab for auto-mount on reboot..."
echo "$PERSIST_DISK $MOUNT_POINT ext4 defaults 0 2" | sudo tee -a /etc/fstab

# -----------------------------
# 2. Install Docker & Docker Compose
# -----------------------------
echo "Installing dependencies..."
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg lsb-release

echo "Adding Docker GPG key..."
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo "Adding Docker repository..."
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

echo "Installing Docker..."
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

echo "Enabling Docker to start on boot..."
sudo systemctl enable docker
sudo systemctl start docker

# Optional: allow user to run docker without sudo
sudo usermod -aG docker $USER
echo "You may need to log out and back in for Docker permissions to take effect."

# -----------------------------
# 3. Create Docker Compose directory & files
# -----------------------------
DEPLOY_DIR="$HOME/chromadb"
mkdir -p $DEPLOY_DIR
cd $DEPLOY_DIR

echo "Creating docker-compose.yml..."
cat > docker-compose.yml <<EOF
version: "3.9"
services:
  chroma:
    image: chromadb/chroma
    volumes:
      - /data:/data
    ports:
      - "8000:8000"
    restart: unless-stopped
    environment:
      - PERSIST_DIRECTORY=/data
      - CHROMA_OPEN_TELEMETRY__ENDPOINT=http://otel-collector:4317/
      - CHROMA_OPEN_TELEMETRY__SERVICE_NAME=chroma
    networks:
      - internal
    depends_on:
      - otel-collector
      - zipkin

  zipkin:
    image: openzipkin/zipkin
    ports:
      - "9411:9411"
    networks:
      - internal

  otel-collector:
    image: otel/opentelemetry-collector-contrib:0.111.0
    command: ["--config=/etc/otel-collector-config.yaml"]
    volumes:
      - ./otel-collector-config.yaml:/etc/otel-collector-config.yaml
    networks:
      - internal

networks:
  internal:
EOF

echo "Creating otel-collector-config.yaml..."
cat > otel-collector-config.yaml <<EOF
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

exporters:
  debug:
  zipkin:
    endpoint: "http://zipkin:9411/api/v2/spans"

service:
  pipelines:
    traces:
      receivers: [otlp]
      exporters: [zipkin, debug]
EOF

# -----------------------------
# 4. Create systemd service for Docker Compose
# -----------------------------
echo "Creating systemd service for ChromaDB..."
sudo tee /etc/systemd/system/chromadb.service > /dev/null <<EOF
[Unit]
Description=ChromaDB Docker Compose Stack
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
WorkingDirectory=$DEPLOY_DIR
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

echo "Reloading systemd daemon..."
sudo systemctl daemon-reload

echo "Enabling ChromaDB service to start on boot..."
sudo systemctl enable chromadb

echo "Starting ChromaDB stack..."
sudo systemctl start chromadb

# -----------------------------
# 5. Summary
# -----------------------------
echo "ChromaDB deployment completed!"
echo "Persistent data directory: $MOUNT_POINT"
echo "Chroma API port: 8000 (expose via firewall if needed)"
echo "Zipkin port: 9411 (internal only or expose if needed)"
echo "Docker Compose stack auto-starts on reboot."
