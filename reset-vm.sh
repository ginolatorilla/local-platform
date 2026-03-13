#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(readlink -f $(dirname "${BASH_SOURCE[0]}"))"

echo '=== 👀 Checking if required tools are installed...'
for tool in lima; do
  if command -v "$tool" > /dev/null; then
    echo "--- ✅ $tool is installed"
  else
    echo "--- ❌ $tool is not installed"
    exit 1
  fi
done

limactl stop k8s --tty=false -f
cp -f $PROJECT_DIR/k8s.lima.yaml ~/.lima/k8s/lima.yaml
limactl start --name k8s --tty=false \
  --mount $PROJECT_DIR/outputs:w \
  --mount $PROJECT_DIR/kubeadm
