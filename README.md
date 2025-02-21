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
- Terraform

## Installation

1. Change the variables in the inventory file at [ansible/inventory.yaml](./ansible/inventory.yaml).
2. Run `./install.sh`. Call with `--check --diff` for a dry-run.

## Port forwarding

Lima automatically forwards the following localhost ports to the host:

| Port | Service                |
| ---- | ---------------------- |
| 80   | HAProxy HTTP listener  |
| 443  | HAProxy HTTPS listener |
| 6443 | Kubernetes API         |

## Ingress

HAProxy acts as the external load balancer for this cluster. HTTPS connections will pass through and terminated by
the ingress controller. Each ingress must have Certmanager annotations so they will have their own TLS certificates.

The certificate authority is generated to `./outputs/certs/ownca.crt`. Make sure you install this CA to your host.

Since the ingresses will be listening to hostnames, make sure you add them to your `/etc/hosts` file.

## Filesystem mounts

The `./outputs/vm-storage` folder is mounted to the VM as `/mnt/data`. The PV provisioner (based from Rancher)
will mount volumes to this directory, ensuring application data will survive if the cluster is destroyed.
