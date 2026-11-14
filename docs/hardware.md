# Hardware

Four Raspberry Pi 4 Model B boards, each booting from a USB SSD, form the
cluster. Two additional boards (`rpi-argon`, `rpi-retropie`) were removed from
the cluster on 2026-11-14 after being unreachable for an extended period. See
[cluster-status.md](cluster-status.md).

## Bill of materials

| Component | Detail |
|---|---|
| Board | Raspberry Pi 4 Model B Rev 1.2 |
| SoC | Broadcom BCM2711, 4 × Cortex-A72 |
| RAM | 4 GB per node (`3,937,188–3,937,196 Ki` allocatable) |
| Boot disk | PNY CS900 500 GB SSD over USB |
| Partitioning | `sda1` 256 MB vfat `/boot`, `sda2` ~465 GB ext4 `/` |
| Network | On-board Gigabit Ethernet (`eth0`) |
| Wi-Fi | Disabled via `dtoverlay=disable-wifi` |
| Bluetooth | Disabled via `dtoverlay=disable-bt` |
| Cooling | Active cooling assumed (all live nodes idle at 52–55 °C) |
| Power | Official 5 V / 3 A USB-C supply per node |

There is no SD card in any node: the firmware, `/boot`, and root filesystem all
live on the USB SSD.

## Operating system

| | |
|---|---|
| Distribution | Debian GNU/Linux 11 (bullseye), 64-bit |
| Kernel | `5.10.92-v8+` (Raspberry Pi kernel) |
| Init | systemd |
| Swap | Disabled (`swapon --show` empty) |
| Container runtime | containerd `1.5.8-k3s1` (bundled with k3s) |

## Nodes

| Hostname | IP | Role | State |
|---|---|---|---|
| `kube1` | 192.168.0.61 | k3s server (control plane) | Ready |
| `kube2` | 192.168.0.62 | k3s agent | Ready (has a broken extra `k3s.service` unit) |
| `kube3` | 192.168.0.63 | k3s agent | Ready |
| `kube4` | 192.168.0.64 | k3s agent | Ready |

`rpi-argon` (192.168.0.37) and `rpi-retropie` (192.168.0.7) were removed from
the cluster on 2026-11-14; the Node objects, stale pods, and Longhorn node
records are gone.

All four current nodes use the same `/etc/hosts` mapping:

```
192.168.0.61 kube1 kube1.devinflake.com
192.168.0.62 kube2 kube2.devinflake.com
192.168.0.63 kube3 kube3.devinflake.com
192.168.0.64 kube4 kube4.devinflake.com
```

## Boot configuration

`/boot/config.txt` (relevant lines):

```ini
arm_64bit=1
arm_boost=1
dtoverlay=vc4-kms-v3d
dtoverlay=disable-wifi
dtoverlay=disable-bt
over_voltage=6
arm_freq=2000
gpu_mem=16
```

- CPU overclock to 2.0 GHz with `over_voltage=6`.
- GPU memory reduced to 16 MB (headless).
- Wi-Fi and Bluetooth radios disabled; networking is wired only.

`/boot/cmdline.txt` (single line, node-specific `PARTUUID`):

```
console=serial0,115200 console=tty1 root=PARTUUID=<uuid>-02 rootfstype=ext4 \
fsck.repair=yes rootwait cgroup_enable=cpuset cgroup_enable=memory \
cgroup_memory=1 swapaccount=1
```

The four `cgroup_*` / `swapaccount` arguments are **required** for Kubernetes
and must be preserved when reimaging.

## Networking

Static addressing is configured in `/etc/dhcpcd.conf`, with an entry for both
`eth0` and `wlan0` (the `wlan0` entry is inert because Wi-Fi is disabled):

```
interface eth0
static ip_address=192.168.0.61/24
static routers=192.168.0.1
static domain_name_servers=208.67.220.220 208.67.222.222

interface wlan0
static ip_address=192.168.0.61/24
static routers=192.168.0.1
static domain_name_servers=208.67.220.220 208.67.222.222
```

- Router: `192.168.0.1`
- Upstream DNS: OpenDNS (`208.67.220.220`, `208.67.222.222`)
- The MetalLB pool (`192.168.0.201–250`) is **outside** the static node range.
- Nodes are dual-homed in name only; only `eth0` is active.

## Installed packages

Beyond the base Debian image:

```
ca-certificates
curl
jq
nfs-common          # Longhorn RWX volumes (mysite-content)
open-iscsi          # Longhorn block devices; iscsid active on every node
openssh-server
```

`open-iscsi` and `nfs-common` are Longhorn prerequisites and must be installed
before k3s/Longhorn.

## Health baseline

Measured 2026-11-14 on the four live nodes:

| Node | Uptime | Load (1/5/15) | Memory used | Rootfs used | Temp | `get_throttled` |
|---|---|---|---|---|---|---|
| kube1 | 31w 2d | 0.60 / 0.60 / 0.75 | 1296 / 3844 MB | 26 G / 459 G | 52.5 °C | `0x0` |
| kube2 | 31w 2d | 0.15 / 0.27 / 0.35 | 607 / 3844 MB | 26 G / 459 G | 53.5 °C | `0x0` |
| kube3 | 31w 2d | 0.22 / 0.28 / 0.27 | 596 / 3844 MB | 8.8 G / 459 G | 52.5 °C | `0x0` |
| kube4 | 31w 2d | — | — | — | 54.5 °C | `0x0` |

No under-voltage or thermal throttling has occurred. Disk use is dominated by
container images and Longhorn replicas.
