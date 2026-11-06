#!/usr/bin/env bash
# Run once as root on build VM 192.168.0.108. Formats ONLY the new image file.
set -euo pipefail
image=/aosp-build-volume.img
mountpoint=/work
test "$(id -u)" -eq 0
test "$(findmnt -n -o SOURCE /)" = /dev/sda2
test "$(findmnt -n -o FSTYPE /)" = ext4
test ! -e "$image"
test ! -e "$mountpoint"
truncate -s 600G "$image"
mkfs.ext4 -F -L aospbuild -m 0 "$image"
mkdir "$mountpoint"
mount -o loop "$image" "$mountpoint"
if ! id aosp >/dev/null 2>&1; then
    useradd -m -s /bin/bash aosp
fi
install -d -m 0755 -o aosp -g aosp "$mountpoint/aosp"
printf '%s %s ext4 loop,nofail 0 0\n' "$image" "$mountpoint" >> /etc/fstab
systemctl daemon-reload
findmnt "$mountpoint"
df -hT "$mountpoint"
