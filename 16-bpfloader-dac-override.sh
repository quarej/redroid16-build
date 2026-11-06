#!/usr/bin/env bash
# VM .108: give the bpfloader service CAP_DAC_OVERRIDE.
# Root cause: the container's bpffs root /sys/fs/bpf is chmod'd to 0555 by
# something before netbpfload runs (fresh kernel default is 1777). netbpfload
# runs as uid 0 with capabilities CHOWN SYS_ADMIN NET_ADMIN (no DAC_OVERRIDE),
# so mkdir /sys/fs/bpf/tethering fails EACCES (0555 has no write bit for
# anyone). Real Android must run netbpfload while the root is still writable
# (1777), but in this LXC the 0555 chmod wins the race. Adding DAC_OVERRIDE
# lets netbpfload (and the exec'd Rust bpfloader, which inherits permitted
# caps) create and write the bpf subdirectories regardless of root mode.
# Does NOT grant the container any host device, sysctl, or bpffs access.
set -euo pipefail
test "$(id -u)" -eq 0
test "$(findmnt -n -o TARGET /work)" = /work
RC=/work/redroid16-lxc-rootfs/system/apex/com.android.tethering/etc/netbpfload.35rc
test -f "$RC"
grep -q '^    capabilities CHOWN SYS_ADMIN NET_ADMIN$' "$RC"
cp -a "$RC" "$RC.before-dacoverride"
sed -i 's/^    capabilities CHOWN SYS_ADMIN NET_ADMIN$/    capabilities CHOWN SYS_ADMIN NET_ADMIN DAC_OVERRIDE/' "$RC"
echo "=== modified $RC ==="
grep -n "capabilities\|service bpfloader\|user root" "$RC"
echo "=== backup ==="
ls -l "$RC.before-dacoverride"
echo "Modified build rootfs .35rc; CT not updated."
