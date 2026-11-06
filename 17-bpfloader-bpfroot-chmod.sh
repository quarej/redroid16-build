#!/usr/bin/env bash
# VM .108: make netbpfload/bpfloader re-open the bpffs root before mkdir.
# Root cause: the container's bpffs root /sys/fs/bpf is locked to mode 0555 by
# something before netbpfload runs (fresh kernel default is 1777). netbpfload
# runs as uid 0 but with capabilities CHOWN SYS_ADMIN NET_ADMIN (no
# DAC_OVERRIDE), so mkdir /sys/fs/bpf/tethering fails EACCES. We are the owner
# of the root, so chmod it back to 1777 immediately before every mkdir. This is
# race-free and applies to both the mainline netbpfload and the exec'd Rust
# bpfloader (its createSysFsBpfSubDir is in system/bpf/loader/Loader.cpp).
# Does NOT grant the container any host device, sysctl, or bpffs access.
set -euo pipefail
test "$(id -u)" -eq 0
test "$(findmnt -n -o TARGET /work)" = /work
runuser -u aosp -- python3 - <<'PY'
from pathlib import Path

OLD = '''        errno = 0;
        int ret = mkdir(s.c_str(), S_ISVTX | S_IRWXU | S_IRWXG | S_IRWXO);
        if (ret && errno != EEXIST) {
'''
NEW = '''        errno = 0;
        // LXC: the bpffs root may be locked to 0555 before we run; we are uid 0
        // and its owner, so re-open it right before creating subdirectories.
        if (chmod("/sys/fs/bpf", S_ISVTX | S_IRWXU | S_IRWXG | S_IRWXO) != 0 &&
            errno != ENOENT) {
            ALOGE("chmod /sys/fs/bpf 1777 failed: %s", std::strerror(errno));
        }
        errno = 0;
        int ret = mkdir(s.c_str(), S_ISVTX | S_IRWXU | S_IRWXG | S_IRWXO);
        if (ret && errno != EEXIST) {
'''

for p in [
    Path('/work/aosp/source/packages/modules/Connectivity/bpf/loader/NetBpfLoad.cpp'),
    Path('/work/aosp/source/system/bpf/loader/Loader.cpp'),
]:
    s = p.read_text()
    if s.count(OLD) != 1:
        raise SystemExit(f'Refusing unexpected context in {p}: count={s.count(OLD)}')
    p.write_text(s.replace(OLD, NEW, 1))
    print(f'patched {p}')
PY
runuser -u aosp -- git -C /work/aosp/source/packages/modules/Connectivity diff --check
runuser -u aosp -- git -C /work/aosp/source/system/bpf diff --check
runuser -u aosp -- bash -c '
    set -eo pipefail
    cd /work/aosp/source
    source build/envsetup.sh
    lunch redroid_x86_64-bp2a-userdebug
    m -j4 netbpfload bpfloader
' > /work/aosp/netbpfload-bpfroot-chmod-build.log 2>&1
echo 'Build done.'
B=/work/aosp/source/out/target/product/redroid_x86_64
ls -l "$B/apex/com.android.tethering/bin/netbpfload" "$B/system/bin/bpfloader"
echo '=== strings check ==='
strings "$B/apex/com.android.tethering/bin/netbpfload" | grep -F "chmod /sys/fs/bpf 1777 failed" || echo "NET MISSING"
strings "$B/system/bin/bpfloader" | grep -F "chmod /sys/fs/bpf 1777 failed" || echo "BPFLOADER MISSING"
md5sum "$B/apex/com.android.tethering/bin/netbpfload" "$B/system/bin/bpfloader"
