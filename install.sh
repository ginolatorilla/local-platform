#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(readlink -f $(dirname "${BASH_SOURCE[0]}"))"

echo '👀 Checking if required tools are installed...'
for tool in kubectl helm lima docker skopeo htpasswd; do
  if command -v "$tool" > /dev/null; then
    echo "-- ✅ $tool is installed"
  else
    echo "-- ❌ $tool is not installed"
    exit 1
  fi
done

echo '✨ Generating certificates (own CA + registry, matching playbook)...'
CERTS_DIR="$PROJECT_DIR/outputs/certs"
mkdir -p "$CERTS_DIR"

# Own CA: key → CSR (CA:TRUE, keyCertSign) → self-signed cert
[ -f "$CERTS_DIR/ownca.key" ]  || openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out "$CERTS_DIR/ownca.key"
[ -f "$CERTS_DIR/ownca.csr" ]  || openssl req -new -key "$CERTS_DIR/ownca.key" -out "$CERTS_DIR/ownca.csr" -subj "/CN=My Local Platform" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign"
[ -f "$CERTS_DIR/ownca.crt" ]  || openssl x509 -req -in "$CERTS_DIR/ownca.csr" -signkey "$CERTS_DIR/ownca.key" -out "$CERTS_DIR/ownca.crt" -days 3650 -sha256

# Registry: key → CSR (SANs matching playbook) → cert signed by own CA
[ -f "$PROJECT_DIR/registry/certs/tls.key" ] || openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out "$PROJECT_DIR/registry/certs/tls.key"
[ -f "$PROJECT_DIR/registry/certs/tls.csr" ] || openssl req -new -key "$PROJECT_DIR/registry/certs/tls.key" -out "$PROJECT_DIR/registry/certs/tls.csr" -subj "/CN=My Container Registry" \
  -addext "subjectAltName=DNS:registry,DNS:host.lima.internal,DNS:localhost,IP:192.168.5.2,IP:127.0.0.1"
[ -f "$PROJECT_DIR/registry/certs/tls.crt" ] || openssl x509 -req -in "$PROJECT_DIR/registry/certs/tls.csr" -CA "$PROJECT_DIR/outputs/certs/ownca.crt" -CAkey "$PROJECT_DIR/outputs/certs/ownca.key" -CAcreateserial -out "$PROJECT_DIR/registry/certs/tls.crt" -days 3650 -sha256

echo '✅ Certificates generated'
echo "-- Certificate authority: $PROJECT_DIR/outputs/certs/ownca.crt"
echo "-- Registry certificate: $PROJECT_DIR/registry/certs/tls.crt"

echo '🔧 Setting up the container registry...'
echo '-- 🖥️️️️  Starting Docker VM...'
limactl shell docker exit >/dev/null || {
    limactl start --name docker template://docker-rootful --tty=false \
        --rosetta \
        --cpus 4 \
        --memory 8 \
        --disk 100 \
        --mount $PROJECT_DIR/registry/store:w
}

REGISTRY_USERNAME="docker"
REGISTRY_PASSWORD="docker"
echo "-- 🔐 Setting up basic auth for registry ($REGISTRY_USERNAME:$REGISTRY_PASSWORD)..."
[ -f "$PROJECT_DIR/registry/.htpasswd" ] || htpasswd -cbB "$PROJECT_DIR/registry/.htpasswd" "$REGISTRY_USERNAME" "$REGISTRY_PASSWORD"

echo '-- 🚢 Starting container registry...'
docker --context lima compose -p registry -f $PROJECT_DIR/registry/docker-compose.yaml up -d --wait

echo '💿 Pushing images to registry...'
if [ ! -f "$PROJECT_DIR/registry/images.lock" ]; then
for image in $(cat $PROJECT_DIR/images.txt); do
        skopeo --override-os linux copy --dest-tls-verify=false docker://"$image" docker://localhost:5001/"$image"
    done
    touch $PROJECT_DIR/registry/images.lock
fi
echo '-- 🔒 Image lock file created. Delete this to push images again.'

echo '🔧 Setting up Kubernetes cluster...'
echo '-- 🖥️️️️  Starting Kubernetes Control Plane VM...'
limactl shell k8s exit >/dev/null || {
    limactl start --name k8s $PROJECT_DIR/k8s.lima.yaml --tty=false \
        --mount $PROJECT_DIR/outputs:w
}