#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(readlink -f $(dirname "${BASH_SOURCE[0]}"))"

echo '=== 👀 Checking if required tools are installed...'
for tool in kubectl sed lima; do
  if command -v "$tool" > /dev/null; then
    echo "--- ✅ $tool is installed"
  else
    echo "--- ❌ $tool is not installed"
    exit 1
  fi
done

set +e
limactl shell --tty=false k8s <<EOT
sudo su

echo '=== 🔄 Resetting Kubernetes cluster...'
for node in $(kubectl get --no-headers nodes | awk '{print $1}'); do
  kubectl --kubeconfig /etc/kubernetes/admin.conf drain \$node --delete-emptydir-data --force --ignore-daemonsets
done
kubeadm reset -f
iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X
command -v ipvsadm && ipvsadm -C
EOT
set -e

limactl shell --tty=false k8s <<EOT
sudo su

echo '--- ⚙️  Configuring Kubernetes'
install -m 0644 $PROJECT_DIR/kubeadm/etc/kubernetes/audit-policy.yaml /etc/kubernetes/audit-policy.yaml
install -m 0600 $PROJECT_DIR/kubeadm/etc/kubernetes/kubeadm.yaml /etc/kubernetes/kubeadm.yaml

echo '--- ▶️  Restarting Kubernetes services'
systemctl restart kubelet crio

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
echo '--- ✅ Kubernetes cluster installed'