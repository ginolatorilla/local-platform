#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(dirname "${BASH_SOURCE[0]}")"

echo '👀 Checking if required tools are installed...'
for tool in kubectl helm lima docker skopeo; do
  if command -v "$tool" > /dev/null; then
    echo "-- ✅ $tool is installed"
  else
    echo "-- ❌ $tool is not installed"
    exit 1
  fi
done

echo '✨ Generating self-signed certificates...'
mkdir -p "$PROJECT_DIR/outputs/certs"
[ -f "$PROJECT_DIR/outputs/certs/ownca.key" ]  || openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out "$PROJECT_DIR/outputs/certs/ownca.key"
[ -f "$PROJECT_DIR/outputs/certs/ownca.crt" ] || openssl req -x509 -new -nodes -key "$PROJECT_DIR/outputs/certs/ownca.key" -sha256 -days 3650 -out "$PROJECT_DIR/outputs/certs/ownca.crt" -subj "/CN=My Local Platform"
[ -f "$PROJECT_DIR/outputs/certs/registry.key" ] || openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out "$PROJECT_DIR/outputs/certs/registry.key"
[ -f "$PROJECT_DIR/outputs/certs/registry.crt" ] || openssl req -x509 -new -nodes -key "$PROJECT_DIR/outputs/certs/registry.key" -sha256 -days 3650 -out "$PROJECT_DIR/outputs/certs/registry.crt" -subj "/CN=My Container Registry"
echo '✅ Self-signed certificates generated'
echo "-- Certificate authority: $PROJECT_DIR/outputs/certs/ownca.crt"
echo "-- Registry certificate: $PROJECT_DIR/outputs/certs/registry.crt"

echo '🔧 Setting up the container registry...'
limactl shell docker exit >/dev/null || {
    limactl start --name docker template://docker-rootful --tty=false \
    --cpus 4 \
    --memory 8 \
    --disk 100
}