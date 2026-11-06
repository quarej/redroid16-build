#!/usr/bin/env bash
# VM .108: add optional CT-local early init logging, enabled only by the
# marker /system/etc/redroid-lxc-debug in the test rootfs (CT 127).
set -euo pipefail
test "$(id -u)" -eq 0
test "$(findmnt -n -o TARGET /work)" = /work
runuser -u aosp -- python3 - <<'PY'
from pathlib import Path
p = Path('/work/aosp/source/system/core/init/util.cpp')
s = p.read_text()
old = '''void InitKernelLogging(char** argv) {
    SetFatalRebootTarget();
    android::base::InitLogging(argv, &android::base::KernelLogger, InitAborter);
}'''
new = '''void InitKernelLogging(char** argv) {
    SetFatalRebootTarget();
    android::base::InitLogging(argv, &android::base::KernelLogger, InitAborter);
    // Scoped diagnostic: avoid passing the host-global /dev/kmsg into LXC.
    if (access("/system/etc/redroid-lxc-debug", F_OK) == 0) {
        android::base::SetLogger([](android::base::LogId, android::base::LogSeverity,
                                    const char*, const char*, unsigned int,
                                    const char* message) {
            int fd = open("/redroid-lxc-init.log", O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC,
                          0644);
            if (fd >= 0) {
                write(fd, message, strlen(message));
                write(fd, "\\n", 1);
                close(fd);
            }
        });
    }
}'''
if s.count(old) != 1:
    raise SystemExit('Refusing unexpected init logger context or repeat')
p.write_text(s.replace(old, new, 1))
PY
runuser -u aosp -- git -C /work/aosp/source/system/core diff --check
runuser -u aosp -- bash -c '
    set -eo pipefail
    cd /work/aosp/source
    source build/envsetup.sh
    lunch redroid_x86_64-bp2a-userdebug
    m -j4 init_second_stage
' > /work/aosp/init-lxc-log-build.log 2>&1
echo 'Diagnostic init compiled; CT 127 remains untouched.'
ls -lh /work/aosp/source/out/target/product/redroid_x86_64/system/bin/init
