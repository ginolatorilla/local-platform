#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(readlink -f $(dirname "${BASH_SOURCE[0]}"))"

echo '=== 👀 Checking if required tools are installed...'
for tool in kubectl helm lima docker skopeo htpasswd; do
  if command -v "$tool" > /dev/null; then
    echo "--- ✅ $tool is installed"
  else
    echo "--- ❌ $tool is not installed"
    exit 1
  fi
done

echo '=== ✨ Generating certificates (own CA + registry, matching playbook)...'
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

echo '--- ✅ Certificates generated'
echo "--- 👑 Certificate authority: $PROJECT_DIR/outputs/certs/ownca.crt"
echo "--- 📄 Registry certificate: $PROJECT_DIR/registry/certs/tls.crt"

echo '=== 🔧 Setting up the container registry...'
echo '--- 🖥️️️️  Starting Docker VM...'
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
echo "--- 🔐 Setting up basic auth for registry ($REGISTRY_USERNAME:$REGISTRY_PASSWORD)..."
[ -f "$PROJECT_DIR/registry/.htpasswd" ] || htpasswd -cbB "$PROJECT_DIR/registry/.htpasswd" "$REGISTRY_USERNAME" "$REGISTRY_PASSWORD"

echo '--- 🚢 Starting container registry...'
docker --context lima compose -p registry -f $PROJECT_DIR/registry/docker-compose.yaml up -d --wait

echo '--- 💿 Pushing images to registry...'
if [ ! -f "$PROJECT_DIR/registry/images.lock" ]; then
for image in $(cat $PROJECT_DIR/images.txt); do
        skopeo --override-os linux copy --dest-tls-verify=false docker://"$image" docker://localhost:5001/"$image"
    done
    touch $PROJECT_DIR/registry/images.lock
fi
echo '--- 🔒 Image lock file created. Delete this to push images again.'

echo '=== ☸️  Setting up Kubernetes cluster...'
echo '--- 🖥️️️️  Starting Kubernetes Control Plane VM...'
limactl shell k8s exit >/dev/null || {
    limactl start --name k8s $PROJECT_DIR/k8s.lima.yaml --tty=false \
        --mount $PROJECT_DIR/outputs:w \
        --mount $PROJECT_DIR/kubeadm
}

KUBERNETES_VERSION=v1.35
CRIO_VERSION=v1.35
echo '--- 🔧 Installing Kubernetes...'
limactl shell --tty=false k8s <<EOT
sudo su

echo '--- 🔧 Installing prerequisites in the node...'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y apt-transport-https ca-certificates curl gpg software-properties-common

echo '--- 📝 Adding Docker registry to /etc/hosts'
grep -q 'registry$' /etc/hosts || echo '192.168.5.2 registry' >> /etc/hosts

echo '--- 🔑 Installing our own CA certificate in the node'
install -m 0644 $PROJECT_DIR/outputs/certs/ownca.crt /usr/local/share/ca-certificates/ownca.crt
update-ca-certificates

echo '--- ⚙️  Configuring kernel modules'
install -m 0644 $PROJECT_DIR/kubeadm/etc/modules-load.d/k8s.conf /etc/modules-load.d/k8s.conf
modprobe overlay
modprobe br_netfilter
install -m 0644 $PROJECT_DIR/kubeadm/etc/sysctl.d/k8s.conf /etc/sysctl.d/k8s.conf
sysctl --system

echo '--- 🔧 Installing CRIO as container runtime and Kubernetes binaries...'
curl -fsSL https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION/deb/Release.key |
    gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION/deb/ /" |
    tee /etc/apt/sources.list.d/kubernetes.list

curl -fsSL https://download.opensuse.org/repositories/isv:/cri-o:/stable:/$CRIO_VERSION/deb/Release.key |
    gpg --batch --yes --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://download.opensuse.org/repositories/isv:/cri-o:/stable:/$CRIO_VERSION/deb/ /" |
    tee /etc/apt/sources.list.d/cri-o.list

apt-get update
apt-get install -y cri-o kubelet kubeadm kubectl

echo '--- ⚙️  Configuring CRIO'
install -m 0644 $PROJECT_DIR/kubeadm/etc/crio/20-crio.conf /etc/crio/crio.conf.d/20-crio.conf
systemctl reload crio

echo '--- ▶️  Starting Kubernetes services'
systemctl enable kubelet crio
systemctl start kubelet crio

echo '--- ⚙️  Configuring Kubernetes'
install -m 0644 $PROJECT_DIR/kubeadm/etc/kubernetes/audit-policy.yaml /etc/kubernetes/audit-policy.yaml
install -m 0600 $PROJECT_DIR/kubeadm/etc/kubernetes/kubeadm.yaml /etc/kubernetes/kubeadm.yaml

echo '--- 🏁 Initializing Kubernetes cluster...'
if ! kubectl cluster-info --kubeconfig /etc/kubernetes/admin.conf; then
  kubeadm init --config /etc/kubernetes/kubeadm.yaml
fi

echo -e "--- 💾 Saving kubeconfig to \033[32m$PROJECT_DIR/outputs/kubeconfig.conf\033[0m"
cp /etc/kubernetes/admin.conf $PROJECT_DIR/outputs/kubeconfig.conf
EOT

echo '--- ✍️  Rewriting kubeconfig to use localhost:6443'
sed -i '' 's/server: .*:6443/server: https:\/\/localhost:6443/g' $PROJECT_DIR/outputs/kubeconfig.conf

echo '--- 🔍 Checking Kubernetes cluster'
kubectl cluster-info --kubeconfig $PROJECT_DIR/outputs/kubeconfig.conf
echo '---   ✅ Kubernetes cluster installed'

echo '=== 📦 Installing cluster apps...'
helm repo add projectcalico https://docs.tigera.io/calico/charts
helm upgrade --install tigera-operator projectcalico/tigera-operator --version v3.27.3 \
  --namespace tigera-operator --create-namespace --wait --values $PROJECT_DIR/kubernetes/helm-chart-apps/tigera-operator/values.yaml
kubectl wait --for=condition=ready installation.operator.tigera.io/default --timeout=300s
kubectl rollout restart deployment coredns -n kube-system

echo '--- ✅ Cluster apps installed'