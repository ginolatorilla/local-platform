#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(readlink -f $(dirname "${BASH_SOURCE[0]}"))"

echo '=== 👀 Checking if required tools are installed...'
for tool in kubectl terraform jq; do
  if command -v "$tool" > /dev/null; then
    echo "--- ✅ $tool is installed"
  else
    echo "--- ❌ $tool is not installed"
    exit 1
  fi
done

echo '=== ⭐️ Activating HashiCorp Vault...'
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