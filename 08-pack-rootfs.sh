#!/usr/bin/env bash
# VM .108: make an offline experimental LXC rootfs. NOT runtime validated.
set -euo pipefail
root=/work/redroid16-lxc-rootfs
archive=/work/redroid16-lxc-arm64-buildcheck.rootfs.tar.zst
test "$(id -u)" -eq 0
test "$(findmnt -n -o TARGET /work)" = /work
test -d "$root/system/apex/com.android.runtime"
test -d "$root/vendor/apex/com.android.hardware.cas"
test -f "$root/system/lib64/libnb.so"
grep -Fxq 'ro.apex.updatable=false' "$root/system/build.prop"
if find "$root/system/apex" "$root/vendor/apex" -type f \
        \( -name '*.apex' -o -name '*.capex' \) | grep -q .; then
    echo 'Refusing to archive packed APEX files' >&2
    exit 1
fi
test ! -e "$archive"
tar --numeric-owner --acls --xattrs --xattrs-include='*' \
    --one-file-system --zstd -cf "$archive" -C "$root" .
ls -lh "$archive"
df -hT /work
echo 'Archive created but NOT verified to boot in an LXC.'
