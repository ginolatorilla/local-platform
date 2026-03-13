# My Local Platform

This is a laptop-only version of my [home lab](https://github.com/ginolatorilla/k8s-homenet/).

## Specifications

| Item                         | Value                         |
| ---------------------------- | ----------------------------- |
| Hypervisor                   | [Lima VM](https://lima-vm.io) |
| Hypervisor version           | limactl 1.0.1                 |
| Host OS                      | MacOS (Darwin)                |
| Guest OS                     | Ubuntu 22.04                  |
| Guest CPU architecture       | arm64                         |
| Kubernetes version           | 1.35.2                        |
| Container runtime            | CRI-O                         |
| Container runtime version    | 1.35                          |
| Container networking         | Calico                        |
| Container networking version | 3.27.0                        |
| Ingress controller           | Nginx                         |
| Ingress controller version   | 3.4.3                         |
| Private registry (cluster)   | registry:5001                 |
| Private registry (host)      | localhost:5001                |

## Requirements

- limactl
- helm
- kubectl
- docker (cli)
- skopeo
- htpasswd
- sed
- terraform
- jq

## Quickstart

```shell
./install.sh
```

### Resetting the VM

1. Modify `k8s.lima.yaml`
2. Run `./reset-vm.sh`.
3. Wait for all the pods to restart.

### Resetting the cluster

1. Modify any file in `kubeadm/*`
2. Run `./reset-cluster.sh`.
3. Run `./install-sh` to continue with the remaining tasks.

## Port forwarding

Lima automatically forwards the following localhost ports to the host:

| Port | Service                             |
| ---- | ----------------------------------- |
| 80   | Forwarder to Ingress HTTP NodePort  |
| 443  | Forwarder to Ingress HTTPS NodePort |
| 6443 | Kubernetes API                      |
| 5001 | Distribution registry               |

## Ingress

Socat runs as a systemd service in the background that forwards VM ports 80 and 443 to the clusters nodeports.

The certificate authority is generated to `./outputs/certs/ownca.crt`. Make sure you install this CA to your host.

Since the ingresses will be listening to hostnames, make sure you add them to your `/etc/hosts` file
or use `<name>.localhost`.

## Filesystem mounts

The `./outputs/vm-storage` folder is mounted to the VM as `/mnt/data`. The PV provisioner (based from Rancher)
will mount volumes to this directory, ensuring application data will survive if the cluster is destroyed.
