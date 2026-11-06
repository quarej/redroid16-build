#!/usr/bin/env bash
# VM .108: in explicit LXC mode, leave host-global kernel sysctls to PVE.
set -euo pipefail
test "$(id -u)" -eq 0
test "$(findmnt -n -o TARGET /work)" = /work
runuser -u aosp -- python3 - <<'PY'
from pathlib import Path
p = Path('/work/aosp/source/system/core/init/security.cpp')
s = p.read_text()
changes = {
    'Result<void> SetMmapRndBitsAction(const BuiltinArguments&) {':
        'Result<void> SetMmapRndBitsAction(const BuiltinArguments&) {\n'
        '    // LXC shares these sysctls with the host; do not write them.\n'
        '    if (android::base::GetBoolProperty("ro.boot.redroid_lxc_mode", false)) return {};',
    'Result<void> SetKptrRestrictAction(const BuiltinArguments&) {':
        'Result<void> SetKptrRestrictAction(const BuiltinArguments&) {\n'
        '    // Leave host-global kptr_restrict unchanged in LXC mode.\n'
        '    if (android::base::GetBoolProperty("ro.boot.redroid_lxc_mode", false)) return {};',
}
for old, new in changes.items():
    if s.count(old) != 1:
        raise SystemExit(f'Refusing unexpected security.cpp context: {old}')
    s = s.replace(old, new, 1)
p.write_text(s)
PY
runuser -u aosp -- git -C /work/aosp/source/system/core diff --check
runuser -u aosp -- bash -c '
    set -eo pipefail
    cd /work/aosp/source
    source build/envsetup.sh
    lunch redroid_x86_64-bp2a-userdebug
    m -j4 init_second_stage
' > /work/aosp/init-lxc-sysctls-build.log 2>&1
echo 'LXC-scoped init compiled; CT 127 remains untouched.'
ls -lh /work/aosp/source/out/target/product/redroid_x86_64/system/bin/init
