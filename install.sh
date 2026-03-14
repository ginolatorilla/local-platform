#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(readlink -f $(dirname "${BASH_SOURCE[0]}"))"

# Parse CLI options
usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --help            Show this help message and exit"
    echo "  --reset-vm        Reset the VM (useful when modifying the VM configuration)"
    echo "  --reset-cluster   Reset the cluster (useful when modifying the cluster configuration)"
}

main() {
  RESET_VM=0
  RESET_CLUSTER=0

  while [[ $# -gt 0 ]]; do
      case "$1" in
          --help)
              usage
              exit 0
              ;;
          --reset-vm)
              RESET_VM=1
              shift
              ;;
          --reset-cluster)
              RESET_CLUSTER=1
              shift
              ;;
          *)
              echo "Unknown argument: $1"
              usage
              exit 1
              ;;
      esac
  done

  echo '=== 👀 Checking if required tools are installed...'
  for tool in kubectl helm lima docker skopeo htpasswd terraform jq sed; do
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
  if [ $RESET_VM -ne 0 ]; then
    echo '--- 🔄 Resetting Kubernetes Control Plane VM...'
    limactl stop k8s --tty=false -f
  fi
  limactl shell k8s exit >/dev/null || {
      mkdir -p ~/.lima/k8s
      cp -f $PROJECT_DIR/k8s.lima.yaml ~/.lima/k8s/lima.yaml
      limactl start --name k8s --tty=false \
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
  apt-get install -y apt-transport-https ca-certificates curl gpg software-properties-common socat

  echo '--- 🚏 Installing socat port forwarding service...'
  install -m 0755 $PROJECT_DIR/kubeadm/usr/local/bin/socat-fwd-nodeport /usr/local/bin/socat-fwd-nodeport
  install -m 0644 $PROJECT_DIR/kubeadm/etc/systemd/socat-fwd@.service /etc/systemd/system/socat-fwd@.service
  systemctl daemon-reload
  systemctl enable --now socat-fwd@80
  systemctl enable --now socat-fwd@443

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

  if [ $RESET_CLUSTER -ne 0 ]; then
    set +e
    echo '--- 🔄 Resetting Kubernetes cluster...'
    kubeadm reset -f
    iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X
    command -v ipvsadm && ipvsadm -C
    set -e

    echo '--- ▶️  Restarting Kubernetes services'
    systemctl restart kubelet crio
  fi

  echo '--- 🏁 Initializing Kubernetes cluster...'
  if ! kubectl cluster-info --kubeconfig /etc/kubernetes/admin.conf; then
    kubeadm init --config /etc/kubernetes/kubeadm.yaml
  fi

  echo -e "--- 💾 Saving kubeconfig to \033[32m$PROJECT_DIR/outputs/kubeconfig.conf\033[0m"
  cp -f /etc/kubernetes/admin.conf $PROJECT_DIR/outputs/kubeconfig.conf
EOT

  echo '--- ✍️  Rewriting kubeconfig to use localhost:6443'
  sed -i '' 's/server: .*:6443/server: https:\/\/localhost:6443/g' $PROJECT_DIR/outputs/kubeconfig.conf
  export KUBECONFIG=$PROJECT_DIR/outputs/kubeconfig.conf

  echo '--- 🔍 Checking Kubernetes cluster'
  kubectl cluster-info
  echo '--- ✅ Kubernetes cluster installed'

  echo '=== 📦 Installing cluster apps...'
  echo '--- 🔧 Installing Calico...'
  helm repo add projectcalico https://docs.tigera.io/calico/charts
  helm upgrade --install tigera-operator projectcalico/tigera-operator --version v3.27.3 \
    --namespace tigera-operator --create-namespace \
    --values $PROJECT_DIR/kubernetes/helm-chart-apps/tigera-operator/values.yaml \
    --wait --atomic
  kubectl wait --for=condition=ready installation.operator.tigera.io/default --timeout=300s
  kubectl rollout restart deployment coredns -n kube-system

  echo '--- 🔧 Installing ArgoCD...'
  helm upgrade --install argocd oci://ghcr.io/argoproj/argo-helm/argo-cd --version 7.7.3 \
    --namespace argocd --create-namespace \
    --values $PROJECT_DIR/kubernetes/helm-chart-apps/argo-cd/values.yaml \
    --wait --atomic

  echo '--- ⏫ Uploading my own CA in CertManager...'
  kubectl get namespace cert-manager >/dev/null 2>&1 || kubectl create namespace cert-manager
  kubectl get secret own-ca --namespace cert-manager >/dev/null 2>&1 || kubectl create secret tls own-ca --cert=$PROJECT_DIR/outputs/certs/ownca.crt --key=$PROJECT_DIR/outputs/certs/ownca.key -n cert-manager

  echo '--- ▶️  Deploying all other apps with ArgoCD...'
  kubectl apply -f $PROJECT_DIR/kubernetes/argocd-app-of-apps.yaml

  echo '=== ⭐️ Activating HashiCorp Vault...'
  echo '--- Waiting for Vault pod to be created by ArgoCD...'
  for i in $(seq 1 60); do
    if kubectl get pod -l app.kubernetes.io/name=vault -n vault -o name 2>/dev/null | grep -q .; then
      break
    fi
    [ $i -eq 60 ] && { echo 'Timeout waiting for Vault pod to appear'; exit 1; }
    sleep 5
  done
  kubectl wait --for=condition=PodReadyToStartContainers pod -l app.kubernetes.io/name=vault -n vault --timeout=300s

  set +e
  echo '--- 🏁 Initializing Vault'
  status=$(kubectl exec sts/vault -n vault -- vault status -format json 2>/dev/null)
  if echo "$status" | jq -e '.initialized != true' >/dev/null; then
      kubectl exec -n vault sts/vault -- vault operator init > $PROJECT_DIR/outputs/vault_unseal_keys.txt
      [ $? -ne 2 ] && exit $?
  fi

  echo '--- 🔓 Unsealing Vault'
  status=$(kubectl exec sts/vault -n vault -- vault status -format json 2>/dev/null)
  if echo "$status" | jq -e '.sealed == true' >/dev/null; then
      for key in $(grep 'Unseal Key [0-9]\+' $PROJECT_DIR/outputs/vault_unseal_keys.txt | cut -d ':' -f 2); do
          echo "--- 🔓 Unsealing Vault with key $key"
          kubectl exec -n vault sts/vault -- vault operator unseal $key
          [ $? -eq 1 ] && exit $?
          status=$(kubectl exec sts/vault -n vault -- vault status -format json 2>/dev/null)
          echo "$status" | jq -e '.sealed == false' >/dev/null && break
      done
  fi
  set -e

  echo '--- 💾 Saving Vault root token to Terraform repo'
  token=$(grep 'Initial Root Token:' $PROJECT_DIR/outputs/vault_unseal_keys.txt | cut -d ':' -f 2)
  echo "token=\"$token\"" > $PROJECT_DIR/terraform/vault/local.auto.tfvars

  echo '=== ✨ Running Terraform to configure Vault...'
  cd $PROJECT_DIR/terraform/vault
  terraform init -reconfigure
  terraform apply -auto-approve
}

main "$@"