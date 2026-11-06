#!/usr/bin/env bash
# VM .108: build complete patched Redroid 16 tree, not yet an LXC image.
set -euo pipefail
test "$(id -u)" -eq 0
test "$(findmnt -n -o TARGET /work)" = /work
test -f /work/aosp/source/device/redroid/AndroidProducts.mk
test -f /work/aosp/source/system/apex/apexd/apexd.cpp
runuser -u aosp -- bash -c '
    set -eo pipefail
    cd /work/aosp/source
    source build/envsetup.sh
    lunch redroid_x86_64-bp2a-userdebug
    m -j4
' > /work/aosp/full-build.log 2>&1
echo 'FULL AOSP/REDROID BUILD SUCCESS; LXC packaging and validation still required.'
tail -25 /work/aosp/full-build.log
df -hT /work
