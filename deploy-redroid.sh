#!/usr/bin/env bash
# deploy-redroid.sh - one-shot create + configure + boot a redroid16 x86_64 LXC CT.
# Usage: deploy-redroid.sh <ctid> <ip-suffix> [hostname]
#   ctid: container ID (e.g. 162)
#   ip-suffix: last octet of the guest IP, e.g. 162 -> 192.168.0.162
#   hostname: optional (default ctredroid<ctid>)
set -euo pipefail
TEMPLATE=/var/lib/vz/template/cache/redroid16-lxc-x86_64-rootfs.tar.zst
ID=${1:?Usage: deploy-redroid.sh <ctid> <ip-suffix> [hostname]}
SUF=${2:?Usage: deploy-redroid.sh <ctid> <ip-suffix> [hostname]}
HOST=${3:-ctredroid$ID}
IP="192.168.0.$SUF"
[ -f "$TEMPLATE" ] || { echo "FATAL: missing template $TEMPLATE"; exit 1; }
pct status $ID >/dev/null 2>&1 && { echo "FATAL: CT $ID already exists"; exit 1; }

echo "== [1/6] creating CT $ID (privileged, from $TEMPLATE) =="
pct create $ID "$TEMPLATE" --storage local-lvm --ostype unmanaged \
  --hostname "$HOST" --cores 4 --memory 6144 --swap 0 --unprivileged 0 --rootfs local-lvm:16

echo "== [2/6] network =="
pct set $ID --net0 "name=eth0,bridge=vmbr0,firewall=1,ip=dhcp,type=veth"

CONF=/etc/pve/lxc/$ID.conf
AA=/etc/apparmor.d/lxc/lxc-container-$ID
AUTODEV=/etc/lxc/ct$ID-autodev.conf
echo "== [3/6] entrypoint + lxc config + apparmor + autodev =="
pct set $ID --entrypoint "/init qemu=1 androidboot.hardware=redroid androidboot.redroid_gpu_mode=guest androidboot.redroid_lxc_mode=1 androidboot.use_memfd=1 ro.dalvik.vm.native.bridge=libnb.so"
echo "# Only CT $ID. 128 MB private /dev tmpfs for Android property areas." > $AUTODEV
echo "lxc.autodev = 1" >> $AUTODEV
echo "lxc.autodev.tmpfs.size = 128000000" >> $AUTODEV
add() { grep -qF "$1" $CONF || echo "$1" >> $CONF; }
add "lxc.mount.auto: proc:mixed sys:ro cgroup:rw"
add "lxc.include: $AUTODEV"
add "lxc.apparmor.profile: lxc-container-$ID"
add "lxc.apparmor.raw: mount fstype=devpts,"
add "lxc.apparmor.raw: mount fstype=binder,"
add "lxc.apparmor.raw: mount fstype=cgroup2 -> /sys/fs/cgroup/,"
add "lxc.apparmor.raw: mount fstype=bpf,"
add "lxc.mount.entry: tmpfs sys/fs/fuse/connections tmpfs ro,nosuid,nodev,noexec,size=1m,create=dir 0 0"
add "lxc.mount.entry: /dev/dri/card0 dev/dri/card0 none bind,optional,create=file 0 0"
add "lxc.mount.entry: /dev/dri/renderD128 dev/dri/renderD128 none bind,optional,create=file 0 0"
add "lxc.mount.entry: /dev/fuse dev/fuse none bind,optional,create=file 0 0"
add "lxc.cgroup2.devices.allow: c 237:* rwm"
add "lxc.cgroup2.devices.allow: c 226:0 rwm"
add "lxc.cgroup2.devices.allow: c 226:128 rwm"
add "lxc.cgroup2.devices.allow: c 10:229 rwm"
if [ -f /etc/apparmor.d/lxc/lxc-container-127 ]; then
  sed "s/lxc-container-127/lxc-container-$ID/g" /etc/apparmor.d/lxc/lxc-container-127 > $AA
  apparmor_parser -r $AA 2>/dev/null || true
else
  echo "WARN: no apparmor template lxc-container-127"
fi

echo "== [4/6] set guest IP =="
LV=$(pct config $ID | awk "/^rootfs:/{print \$2}" | sed "s/.*://;s/,size=.*//")
D=/mnt/fix$ID
mkdir -p $D
lvchange -ay pve/$LV 2>/dev/null
sleep 1
mount /dev/pve/$LV $D 2>/dev/null || mount /dev/mapper/pve-$LV $D 2>/dev/null || true
RC=$D/vendor/etc/init/redroid.common.rc
if [ -f "$RC" ]; then
  sed -i "s/192.168.0.[0-9]*\/24 dev eth0/$IP\/24 dev eth0/" "$RC"
  echo "  guest IP set to $IP"
fi
umount $D 2>/dev/null; rmdir $D 2>/dev/null || true

echo "== [5/6] start CT $ID =="
pct start $ID

echo "== [6/6] wait for boot_completed =="
NS=/sys/fs/cgroup/lxc/$ID/ns
for i in $(seq 1 60); do
  st=$(pct status $ID 2>/dev/null | awk "{print \$2}" || echo unknown)
  if [ "$st" != "running" ]; then
    echo "  CT not running (state=$st), restarting..."
    pct start $ID 2>/dev/null || true
    sleep 8
    continue
  fi
  mkdir -p $NS/system/init $NS/apps 2>/dev/null || true
  for p in $(cat $NS/cgroup.procs 2>/dev/null); do echo $p > $NS/system/init/cgroup.procs 2>/dev/null || true; done
  echo "+cpuset +cpu +io +memory +pids" > $NS/cgroup.subtree_control 2>/dev/null || true
  echo "+cpuset +cpu +io +memory +pids" > $NS/apps/cgroup.subtree_control 2>/dev/null || true
  s=$(pct exec $ID -- /system/bin/getprop sys.boot_completed 2>/dev/null | tr -d " \r" || echo "")
  if [ "$s" = "1" ]; then echo "BOOT COMPLETED"; break; fi
  sleep 10
done
echo ""
echo "==== 部署完成 ===="
echo "  CT:  $ID   status: $(pct status $ID 2>/dev/null | awk '{print $2}')"
echo "  IP:  192.168.0.$SUF"
echo "  adb: adb connect 192.168.0.$SUF:5555"
echo "  shell: pct exec $ID -- /system/bin/getprop sys.boot_completed"
