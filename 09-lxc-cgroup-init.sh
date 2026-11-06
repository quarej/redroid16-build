#!/usr/bin/env bash
# VM .108 only. For LXC mode, PVE owns the cgroup hierarchy; Android init
# must not remount it read-write. Existing normal-boot behavior is unchanged.
set -euo pipefail
test "$(id -u)" -eq 0
test "$(findmnt -n -o TARGET /work)" = /work
runuser -u aosp -- python3 - <<'PY'
from pathlib import Path
p = Path('/work/aosp/source/system/core/init/init.cpp')
s = p.read_text()
old = '''static Result<void> SetupCgroupsAction(const BuiltinArguments&) {
    if (!CgroupsAvailable()) {'''
new = '''static Result<void> SetupCgroupsAction(const BuiltinArguments&) {
    // The container runtime owns cgroups; never remount the host hierarchy.
    if (GetBoolProperty("ro.boot.redroid_lxc_mode", false)) {
        LOG(INFO) << "LXC mode: skipping Android cgroup mounts";
        return {};
    }
    if (!CgroupsAvailable()) {'''
if s.count(old) != 1:
    raise SystemExit('Refusing unexpected init.cpp context or duplicate patch')
p.write_text(s.replace(old, new, 1))
PY
runuser -u aosp -- git -C /work/aosp/source/system/core diff --check
runuser -u aosp -- bash -c '
    set -eo pipefail
    cd /work/aosp/source
    source build/envsetup.sh
    lunch redroid_x86_64-bp2a-userdebug
    m -j4 init_second_stage
' > /work/aosp/init-lxc-cgroup-build.log 2>&1
echo 'LXC-scoped init compiled; not yet installed in any CT.'
ls -lh /work/aosp/source/out/target/product/redroid_x86_64/system/bin/init
