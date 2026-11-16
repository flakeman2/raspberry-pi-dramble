# Full redeploy: from bare Pis to a running cluster

This is the end-to-end procedure to rebuild the cluster from bare Pis. It
reproduces the stack pinned in this repository:

- k3s `v1.36.6+k3s1`, single server
- MetalLB `0.16.2` (vendored native manifest + `IPAddressPool`/`L2Advertisement` CRs)
- Longhorn `1.13.0`
- Traefik chart `42.4.0` (app `v3.7.18`) with ACME
- Prometheus chart `29.47.2` (app `3.16.0`)
- Grafana chart `14.4.1` (app `13.3.1`), from the `grafana-community` Helm repo
- Workloads in `cluster/workloads/`

> **Note:** these pins replaced the 2021 stack (k3s `v1.22.5+k3s1`, Traefik
> `2.5.6`, …) on 2026-11-14, ahead of this reimage — see
> [upgrade.md](upgrade.md). What was actually running until then is recorded in
> [cluster-status.md](cluster-status.md). The manifests in this repository are
> the current ones; there is no old-version path to reproduce any more.

## 0. Prerequisites

On the workstation that will drive the install:

```bash
kubectl version --client
helm version
```

Install `helm` if needed (<https://helm.sh/docs/intro/install/>). On Debian/Ubuntu:

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

You also need SSH access to the nodes and the ability to write the SSD of each
Pi.

## 1. Reimage the Pis

### Image

Use **Ubuntu Server 26.04 LTS for Raspberry Pi** (64-bit). The nodes as
reimaged on 2026-11-15 report:

```
Ubuntu 26.04.1 LTS
7.0.0-1023-raspi
```

Write the image directly to the **USB SSD** (not an SD card). Raspberry Pi
Imager can target a USB device; alternatively use `dd`/`bmaptool` with the SSD
in a USB adapter.

In Raspberry Pi Imager's advanced settings, set:

- hostname (`kube1` … `kube4`)
- user `pi` with your SSH public key
- SSH enabled
- locale/timezone

### First boot

Boot each node with the SSD attached and log in over SSH. Perform the
node-specific steps below **before** installing k3s.

#### 1.1 Hostname and hosts file

```bash
sudo hostnamectl set-hostname kube1

# drop cloud-init's loopback entry, then install the cluster mapping
sudo sed -i '/^127\.0\.1\.1[[:space:]]/d' /etc/hosts
cat >> /etc/hosts <<'EOF'
192.168.0.61 kube1 kube1.devinflake.com
192.168.0.62 kube2 kube2.devinflake.com
192.168.0.63 kube3 kube3.devinflake.com
192.168.0.64 kube4 kube4.devinflake.com
EOF
```

The same four lines go on every node. Verify with `getent hosts kube2`.

#### 1.2 Static IP

Edit `/etc/netplan/50-cloud-init.yaml` (adjust the address per node):

```yaml
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: false
      addresses:
        - 192.168.0.61/24
      routes:
        - to: default
          via: 192.168.0.1
```

Check with `sudo netplan generate`, apply with `sudo netplan apply`. DNS comes
from the router, so no `nameservers:` block is needed. The image also ships
`dhcpcd`, but nothing is configured there — ignore it.

#### 1.3 Boot configuration

Boot files live under `/boot/firmware/`, with the active kernel and command
line in `/boot/firmware/current/`. Ubuntu already sets `arm_64bit=1`,
`arm_boost=1` and `dtoverlay=vc4-kms-v3d` in `/boot/firmware/config.txt`, so
**no boot changes are required**.

Do **not** carry over the old Debian cgroup arguments
(`cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1 swapaccount=1`):
this kernel is cgroup v2 by default, which Kubernetes prefers. Check with
`stat -fc %T /sys/fs/cgroup` → `cgroup2fs`.

The previous install also overclocked to 2.0 GHz (`over_voltage=6`,
`arm_freq=2000`); that is not set on this image. Add it back only with adequate
cooling.

#### 1.4 Disable swap and install prerequisites

```bash
sudo swapoff -a
sudo apt-get update
sudo apt-get install -y curl ca-certificates jq open-iscsi nfs-common
sudo systemctl enable --now iscsid
```

`open-iscsi` and `nfs-common` are the Longhorn prerequisites. `nfs-common`
supplies the NFS client the node uses to mount RWX volumes — Longhorn's
share-manager serves NFS from inside the cluster, but the mount happens on the
node. Verify:

```bash
systemctl is-active iscsid          # active
command -v mount.nfs                # present (nfs-common)
swapon --show                       # empty
stat -fc %T /sys/fs/cgroup          # cgroup2fs
```

#### 1.5 Reboot

```bash
sudo reboot
```

After reboot, verify the node (`vcgencmd` needs `sudo` on this image):

```bash
hostname
ip -4 addr show eth0
sudo vcgencmd measure_temp
sudo vcgencmd get_throttled         # 0x0
free -m
df -h /
```

Repeat on `kube2`–`kube4` with their own hostnames/IPs. `rpi-argon` and
`rpi-retropie` were removed from the cluster in November 2026 and are not part of
the rebuild.

## 2. Install k3s

### 2.1 Server (`kube1`)

From the repository on `kube1`:

```bash
sudo ./scripts/install-server.sh
```

The script pins `v1.36.6+k3s1` and passes:

```
server --disable servicelb --disable local-storage --disable traefik
```

Retrieve the join token:

```bash
sudo cat /var/lib/rancher/k3s/server/node-token
```

### 2.2 Agents (`kube2`–`kube4`)

Copy the repository or just the script to each agent, then:

```bash
sudo K3S_URL=https://192.168.0.61:6443 \
     K3S_TOKEN='<token>' \
     ./scripts/install-agent.sh
```

The script installs **only** `k3s-agent.service` and disables `k3s.service`.
Do not create a server unit on an agent: the live kube2 acquired a broken
`k3s server --server https://192.168.0.200:6443` unit from an abandoned
kube-vip attempt and looped ~1.58 million times.

### 2.3 kubeconfig on the workstation

```bash
ssh pi@192.168.0.61 'sudo cat /etc/rancher/k3s/k3s.yaml' > ~/.kube/config-dramble-k3s
sed -i 's/127\.0\.0\.1/192.168.0.61/' ~/.kube/config-dramble-k3s
chmod 600 ~/.kube/config-dramble-k3s
export KUBECONFIG=~/.kube/config-dramble-k3s
kubectl get nodes -o wide
```

All intended nodes should be `Ready`. Do not continue until they are.

## 3. Create the Secrets

Apply the namespaces first so the Secrets have somewhere to live:

```bash
kubectl apply -f cluster/namespaces.yaml
```

Create the three required Secrets. See [secrets.md](secrets.md) for details and
rotation notes.

```bash
# Dashboard basic auth (htpasswd format)
kubectl -n default create secret generic authsecret \
  --from-literal=users="$(htpasswd -nbB admin 'CHOOSE-A-PASSWORD')"

# Park-Your-Domain dynamic DNS
kubectl -n default create secret generic dyn-dns-credentials \
  --from-literal=password='CHOOSE-A-PASSWORD'

# Grafana admin
kubectl -n monitoring create secret generic grafana \
  --from-literal=admin-user=admin \
  --from-literal=admin-password='CHOOSE-A-PASSWORD'
```

`htpasswd` comes from `apache2-utils`. If you prefer, copy
`cluster/secrets/examples/*.yaml`, replace the placeholders, and `kubectl apply`
them.

> Never commit real Secret values.

## 4. Install the add-ons and workloads

```bash
export KUBECONFIG=~/.kube/config-dramble-k3s
./scripts/install-addons.sh
```

The script performs, in order:

1. MetalLB namespace, manifest, and address pool
2. Longhorn manifest, waits for the driver deployer and manager
3. Helm repo setup
4. Traefik chart `42.4.0` with `cluster/traefik/values.yaml`
5. Prometheus chart `29.47.2` with chart defaults
6. Grafana chart `14.4.1` with `cluster/monitoring/grafana-values.yaml`
7. Traefik `TLSOption`, `Middleware`, and `IngressRoute` objects
8. Workloads (`cluster/workloads/`)
9. Dashboard `IngressRoute`s
10. Dynamic DNS CronJobs

It fails fast if a required Secret is missing.

### Manual equivalent

If you prefer to run the steps yourself:

```bash
kubectl apply -f cluster/metallb/metallb-v0.16.2.yaml
kubectl -n metallb-system rollout status deploy/controller --timeout=5m
kubectl wait --for condition=established --timeout=60s \
  crd/ipaddresspools.metallb.io crd/l2advertisements.metallb.io
kubectl apply -f cluster/metallb/config.yaml

kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/v1.13.0/deploy/longhorn.yaml
kubectl -n longhorn-system rollout status deploy/longhorn-driver-deployer --timeout=15m

helm repo add traefik https://traefik.github.io/charts
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana-community.github.io/helm-charts
helm repo update

helm install traefik traefik/traefik -n traefik --version 42.4.0 \
  -f cluster/traefik/values.yaml
helm install prometheus prometheus-community/prometheus -n monitoring --version 29.47.2 \
  -f cluster/monitoring/prometheus-values.yaml
helm install grafana grafana/grafana -n monitoring --version 14.4.1 \
  -f cluster/monitoring/grafana-values.yaml

kubectl wait --for condition=established --timeout=60s \
  crd/ingressroutes.traefik.io crd/middlewares.traefik.io crd/tlsoptions.traefik.io
kubectl apply -f cluster/traefik/tlsoption.yaml
kubectl apply -f cluster/traefik/middlewares.yaml
kubectl apply -f cluster/traefik/ingressroutes.yaml
kubectl apply -R -f cluster/workloads
kubectl apply -f cluster/dashboards/ingressroutes.yaml
kubectl apply -f cluster/dns/cronjobs.yaml
```

## 5. Restore the static site content

The current document root is checked in at
`cluster/workloads/mysite/content/`. Once the `mysite-nginx` pod is running:

```bash
kubectl -n mysite-nginx cp cluster/workloads/mysite/content/. \
  deploy/mysite-nginx:/usr/share/nginx/html/
```

Verify:

```bash
kubectl -n mysite-nginx exec deploy/mysite-nginx -- ls -la /usr/share/nginx/html
```

Longhorn volumes are new and empty. Prometheus and Grafana start with empty
databases; historical metrics and Grafana dashboards are not part of this repo.

## 6. DNS and TLS

- Traefik receives `192.168.0.201` from MetalLB.
- Forward TCP 80 and 443 on the router (`192.168.0.1`) to `192.168.0.201`.
- Park-Your-Domain records for `@`, `www`, and `*` are updated every 30 minutes
  by the CronJobs. They discover the WAN address from the request, so no manual
  A-record changes are needed after the first run.
- Traefik obtains Let's Encrypt certificates on first request to each host via
  TLS-ALPN-01. The ACME account email is in `cluster/traefik/values.yaml`
  (`devinflake@gmail.com`); change it if needed.
- Certificate issuance can take a minute. Watch Traefik logs:

```bash
kubectl -n traefik logs deploy/traefik -f | grep -i acme
```

## 7. Validate

```bash
kubectl get nodes
kubectl get pods -A
kubectl get pvc -A
kubectl get svc -A
kubectl -n traefik get svc traefik
kubectl get ingressroute -A
kubectl -n metallb-system get ipaddresspool default -o jsonpath='{.spec.addresses}'
kubectl -n longhorn-system get volumes.longhorn.io
kubectl top nodes
```

Expected:

- 4 (or 6) nodes `Ready`
- all pods `Running`/`Completed`
- every PVC `Bound`
- Traefik Service `EXTERNAL-IP=192.168.0.201`
- Longhorn volumes `healthy`
- MetalLB pool `192.168.0.201-192.168.0.250`

End-to-end checks from the LAN:

```bash
for h in devinflake.com blog.devinflake.com grafana.devinflake.com; do
  printf '%-26s ' "$h"
  curl -s -o /dev/null -H "Host: $h" -w '%{http_code} -> %{redirect_url}\n' http://192.168.0.201/
done

curl -sk -o /dev/null -H 'Host: blog.devinflake.com' \
  -w '%{http_code}\n' https://192.168.0.201/

echo | openssl s_client -connect 192.168.0.201:443 \
  -servername grafana.devinflake.com 2>/dev/null | \
  openssl x509 -noout -subject -issuer -dates
```

The dashboards at `traefik.` and `longhorn.` require the basic-auth credentials
from step 3.

## 8. Post-install notes

- `pi-hole` was removed from the manifests on 2026-11-14 (its `ExternalName`
  target never answered). Delete the `pi-hole.devinflake.com` DNS record at the
  provider if it is still there.
- The Grafana datasource is provisioned from `cluster/monitoring/grafana-values.yaml`.
  Grafana has no dashboards; import them after the rebuild if desired.
- The Prometheus chart runs with `cluster/monitoring/prometheus-values.yaml`
  (chart defaults plus a resource budget for the server). It creates server,
  alertmanager, pushgateway, kube-state-metrics, and node-exporter.
- If you return `rpi-argon`/`rpi-retropie` to service, reimage them and join
  them as agents with `install-agent.sh`. They will register as new nodes. Do not
  wipe their Longhorn disks blindly: existing replicas re-register from
  `/var/lib/longhorn` if the disk data is intact.
