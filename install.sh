#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(dirname "${BASH_SOURCE[0]}")"
VENV_DIR="${PROJECT_DIR}/.venv"
ANSIBLE_DIR="${PROJECT_DIR}/ansible"

if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
fi

source "$VENV_DIR"/bin/activate
pip install -r "$ANSIBLE_DIR"/requirements.txt
ansible-galaxy collection install -r "$ANSIBLE_DIR"/requirements.yaml
ansible-playbook "$ANSIBLE_DIR"/playbook.yaml -i "$ANSIBLE_DIR"/inventory.ini "$@"
