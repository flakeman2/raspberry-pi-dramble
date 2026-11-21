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
| RAM | 4 GB per node (~3,777 MiB visible on Ubuntu 26.04) |
| Boot disk | PNY CS900 500 GB SSD over USB |
| Partitioning | `sda1` 512 MB vfat `/boot/firmware`, `sda2` ~465 GB ext4 `/` |
| Network | On-board Gigabit Ethernet (`eth0`), static addressing |
| Wi-Fi | Disabled at firmware level (`dtoverlay=disable-wifi` — no `wlan0` exists), and `wpa_supplicant.service` disabled too |
| Bluetooth | Disabled at firmware level (`dtoverlay=disable-bt` — `/sys/class/bluetooth` empty) |
| Cooling | Heatsinks + active cooling on every node (confirmed by owner 2026-11-16) — idle 45–57 °C with the 2.0 GHz overclock |
| Power | Official 5 V / 3 A USB-C supply per node |

There is no SD card in any node: the firmware, `/boot/firmware`, and root
filesystem all live on the USB SSD.

## Operating system

| | |
|---|---|
| Distribution | Ubuntu Server 26.04.1 LTS (raspi), 64-bit |
| Kernel | `7.0.0-1023-raspi` |
| Init | systemd |
| Swap | Disabled (`swapon --show` empty) |
| Firewall | ufw installed, inactive |
| cgroup | v2 (`cgroup2fs`) — no kernel arguments required |
| Container runtime | containerd, bundled with k3s |

All four nodes were **reimaged on 2026-11-15**. The previous install (Debian 11,
kernel `5.10.92-v8+`, dhcpcd, cgroup v1 kernel arguments) was retired with the
rebuild; see [upgrade.md](upgrade.md).

## Nodes

| Hostname | IP | Role | State |
|---|---|---|---|
| `dflake-nettop` | 192.168.0.44 | k3s server (control plane), x86_64, tainted | **Ready**, `v1.36.6+k3s1` |
| `kube1` | 192.168.0.61 | k3s agent (was the control plane until 2026-11-21) | **Ready**, `v1.36.6+k3s1` |
| `kube2` | 192.168.0.62 | k3s agent | **Ready**, `v1.36.6+k3s1` (only `k3s-agent.service` exists now) |
| `kube3` | 192.168.0.63 | k3s agent | **Ready**, `v1.36.6+k3s1` |
| `kube4` | 192.168.0.64 | k3s agent | **Ready**, `v1.36.6+k3s1` |

`rpi-argon` (192.168.0.37) and `rpi-retropie` (192.168.0.7) were removed from
the cluster on 2026-11-14 and are not part of the rebuild.

All four current nodes use the same `/etc/hosts` mapping. It was recreated on
2026-11-15, replacing cloud-init's `127.0.1.1 <hostname>` line so that nodes
resolve each other by name:

```
192.168.0.44 dflake-nettop dflake-nettop.devinflake.com
192.168.0.61 kube1 kube1.devinflake.com
192.168.0.62 kube2 kube2.devinflake.com
192.168.0.63 kube3 kube3.devinflake.com
192.168.0.64 kube4 kube4.devinflake.com
```

## Boot configuration

Ubuntu keeps the firmware files under `/boot/firmware/`. The active kernel and
command line live in `/boot/firmware/current/` (selected by `autoboot.txt`);
the previous slot is kept in `/boot/firmware/old/`.

`/boot/firmware/config.txt` (relevant lines):

```ini
kernel=vmlinuz
cmdline=cmdline.txt
initramfs initrd.img followkernel
arm_64bit=1
arm_boost=1
dtoverlay=vc4-kms-v3d

# host tuning, restored per action item 16 (2026-11-16)
dtoverlay=disable-wifi
dtoverlay=disable-bt
over_voltage=6
arm_freq=2000
gpu_mem=16
```

- `arm_64bit=1` and `arm_boost=1` select the 64-bit kernel and the boost clock.
- The five tuning lines were **added back on 2026-11-16** (action item 16),
  restoring what the pre-reimage nodes had: radios off at firmware level, 2.0 GHz
  with `over_voltage=6`, GPU memory pinned to 16 MB. Verified on every node —
  no `wlan0`, empty `/sys/class/bluetooth`, `scaling_max_freq=2000000`,
  `get_throttled=0x0`, idle 46–54 °C.
- Because Wi-Fi is gone, **`wpa_supplicant.service` was disabled on all four**
  (`systemctl disable --now wpa_supplicant`) — the image had left it enabled and
  running. Nothing legitimate used it: `NetworkManager` is inactive and
  `systemd-networkd` drives `eth0`.
- Reapply both after any reimage. If Wi-Fi is ever wanted again: delete the two
  `dtoverlay` lines and `systemctl enable --now wpa_supplicant`.

`/boot/firmware/current/cmdline.txt` (single line):

```
console=serial0,115200 multipath=off dwc_otg.lpm_enable=0 console=tty1 \
root=LABEL=writable rootfstype=ext4 rootwait fixrtc
```

**No cgroup arguments are needed.** The previous Debian install required
`cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1 swapaccount=1` to get
cgroup v1; this kernel boots cgroup v2 by default — verify with
`stat -fc %T /sys/fs/cgroup` → `cgroup2fs`, which is what Kubernetes wants
anyway.

## Networking

Static addressing is configured with **netplan**, in
`/etc/netplan/50-cloud-init.yaml`. The image also ships `dhcpcd`, but nothing
is configured there. Every node has the same shape with its own address:

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

Apply changes with `sudo netplan apply`.

- Router: `192.168.0.1`
- DNS: provided by the router (a link-local resolver); no static nameservers in
  netplan. The previous install pointed at OpenDNS directly
  (`208.67.220.220`, `208.67.222.222`).
- The MetalLB pool (`192.168.0.201–250`) is **outside** the static node range
  and is reserved in the router's DHCP configuration (confirmed 2026-11-14), so
  DHCP cannot hand MetalLB's VIP to a client.
- `wlan0` exists but is down; `eth0` is the only active interface.

## Installed packages

Verified present on the base Ubuntu image (2026-11-15):

```
ca-certificates
curl
jq
open-iscsi          # Longhorn block devices
openssh-server
```

`nfs-common` is **not** in the base image and had to be installed on
2026-11-15. Longhorn serves `mysite-content` (RWX) from its share-manager over
NFS, and the *node* needs an NFS client to perform the mount — without it the
pod stalls in `ContainerCreating` with
`MountVolume.MountDevice failed … exit status 32`.

```bash
sudo apt-get install -y nfs-common   # installed on all four, 2026-11-15
```

`open-iscsi` and `nfs-common` are the Longhorn prerequisites; the iSCSI daemon
ships disabled and has to be started:

```bash
sudo systemctl enable --now iscsid    # active and enabled on all four, 2026-11-15
```

## Health baseline

**Live — measured 2026-11-16 after the host tuning of action item 16** (nodes
had rebooted minutes earlier, so uptime is short and kube1's load is still
settling; `vcgencmd` needs `sudo` on this image):

| Node | Uptime | Load (1/5/15) | Memory used | Rootfs used | Temp | `get_throttled` |
|---|---|---|---|---|---|---|
| kube1 | 6m | 1.83 / 1.42 / 0.68 | 1367 / 3828 MB | 8.9 G / 458 G | 44.8 °C | `0x0` |
| kube2 | 27m | 0.67 / 0.77 / 0.77 | 1410 / 3828 MB | 11 G / 458 G | 53.0 °C | `0x0` |
| kube3 | 17m | 0.75 / 0.82 / 0.74 | 1484 / 3828 MB | 11 G / 458 G | 56.9 °C | `0x0` |
| kube4 | 13m | 0.63 / 0.76 / 0.54 | 1180 / 3828 MB | 8.8 G / 458 G | 53.5 °C | `0x0` |

For scale: immediately **before** tuning the same nodes idled at 42.8–50.6 °C.
Settled after the 2.0 GHz + `over_voltage=6` overclock they run 44.8–56.9 °C
(about +1–3 °C, with brief ~60 °C peaks while Longhorn rebuilt replicas right
after each reboot) and `get_throttled` stays `0x0` — no under-voltage, no
thermal throttling. Comfortable margin given heatsinks and active cooling, with
80 °C as the throttle point.

Historical — measured 2026-11-14 on the **previous** install (31 weeks of
uptime, all workloads running):

| Node | Uptime | Load (1/5/15) | Memory used | Rootfs used | Temp | `get_throttled` |
|---|---|---|---|---|---|---|
| kube1 | 31w 2d | 0.60 / 0.60 / 0.75 | 1296 / 3844 MB | 26 G / 459 G | 52.5 °C | `0x0` |
| kube2 | 31w 2d | 0.15 / 0.27 / 0.35 | 607 / 3844 MB | 26 G / 459 G | 53.5 °C | `0x0` |
| kube3 | 31w 2d | 0.22 / 0.28 / 0.27 | 596 / 3844 MB | 8.8 G / 459 G | 52.5 °C | `0x0` |
| kube4 | 31w 2d | — | — | — | 54.5 °C | `0x0` |

In between, immediately after the 2026-11-15 reimage and before anything was
installed: 33–44 min uptime, load under 0.25, ~470 MB used, 3.5 G of 458 G,
39.4 °C.

No under-voltage or thermal throttling has occurred on any node, on either
install.
