#!/usr/bin/env bash
# VM .108: compile the patched Android 16 init/apexd modules before full image.
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
    m -j4 init_second_stage apexd
' > /work/aosp/module-build.log 2>&1
echo 'MODULE BUILD SUCCESS'
tail -20 /work/aosp/module-build.log
df -hT /work
