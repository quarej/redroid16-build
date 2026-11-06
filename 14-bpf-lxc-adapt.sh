#!/usr/bin/env bash
# VM .108: container-safe Android 16 BPF boot path (LXC mode only).
# 1) netbpfload: a failed no-op write to the host-global
#    /proc/sys/kernel/unprivileged_bpf_disabled must not abort boot when
#    ro.boot.redroid_lxc_mode=1 (host value is already 0).
# 2) bpfloader (Rust): tolerate a missing init-provided /dev/kmsg fd instead
#    of panicking; fall back to stderr (logcat still gets every message via
#    the Android logger).
# Does NOT grant the container any host device, sysctl, or bpffs access.
set -euo pipefail
test "$(id -u)" -eq 0
test "$(findmnt -n -o TARGET /work)" = /work
runuser -u aosp -- python3 - <<'PY'
from pathlib import Path

net = Path('/work/aosp/source/packages/modules/Connectivity/bpf/loader/NetBpfLoad.cpp')
s = net.read_text()
old = '''        if (writeProcSysFile("/proc/sys/kernel/unprivileged_bpf_disabled", "0\\n") &&
            isAtLeastKernelVersion(5, 13, 0)) return 1;
'''
new = '''        if (writeProcSysFile("/proc/sys/kernel/unprivileged_bpf_disabled", "0\\n") &&
            isAtLeastKernelVersion(5, 13, 0)) {
            // LXC mode: /proc/sys is host-owned and read-only here, and the host
            // value is already suitable; a failed no-op write must not abort boot.
            if (android::base::GetBoolProperty("ro.boot.redroid_lxc_mode", false)) {
                ALOGE("LXC mode: ignoring unprivileged_bpf_disabled write failure");
            } else {
                return 1;
            }
        }
'''
if s.count(old) != 1:
    raise SystemExit('Refusing unexpected NetBpfLoad.cpp sysctl context or repeat')
net.write_text(s.replace(old, new, 1))

rs = Path('/work/aosp/source/system/bpf/loader/bpfloader.rs')
t = rs.read_text()
old = '    let kmsg_fd = env::var("ANDROID_FILE__dev_kmsg").unwrap().parse::<i32>().unwrap();\n'
new = '''    let kmsg_fd = match env::var("ANDROID_FILE__dev_kmsg").ok().and_then(|v| v.parse::<i32>().ok()) {
        Some(fd) => fd,
        None => {
            // No init-provided kmsg fd (e.g. LXC without /dev/kmsg): log to stderr.
            eprintln!("bpfloader: ANDROID_FILE__dev_kmsg missing; logging to stderr");
            2
        }
    };
'''
if t.count(old) != 1:
    raise SystemExit('Refusing unexpected bpfloader.rs kmsg context or repeat')
rs.write_text(t.replace(old, new, 1))
PY
runuser -u aosp -- git -C /work/aosp/source/packages/modules/Connectivity diff --check
runuser -u aosp -- git -C /work/aosp/source/system/bpf diff --check
runuser -u aosp -- bash -c '
    set -eo pipefail
    cd /work/aosp/source
    source build/envsetup.sh
    lunch redroid_x86_64-bp2a-userdebug
    m -j4 netbpfload bpfloader
' > /work/aosp/bpf-lxc-adapt-build.log 2>&1
echo 'BPF LXC adaptation compiled; no CT updated.'
ls -l /work/aosp/source/out/target/product/redroid_x86_64/apex/com.android.tethering/bin/netbpfload \
      /work/aosp/source/out/target/product/redroid_x86_64/system/bin/bpfloader
