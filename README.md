# My Local Platform

This is a laptop-only version of my [home lab](https://github.com/ginolatorilla/k8s-homenet/).

## Specifications

| Item                         | Value                         |
| ---------------------------- | ----------------------------- |
| Hypervisor                   | [Lima VM](https://lima-vm.io) |
| Hypervisor version           | limactl 1.0.1                 |
| Host OS                      | MacOS (Darwin)                |
| 15.1                         | 22.04                         |
| Guest CPU architecture       | arm64                         |
| Kubernetes version           | 1.31.0                        |
| Container runtime            | CRI-O                         |
| Container runtime version    | 1.31                          |
| Container networking         | Calico                        |
| Container networking version | 3.27.0                        |
| Ingress controller           | Nginx                         |
| Ingress controller version   | 3.4.3                         |

## Requirements

- Python 3

## Installation

1. Change the variables in the inventory file at [ansible/inventory.yaml](./ansible/inventory.yaml).
2. Run `./install.sh`.
