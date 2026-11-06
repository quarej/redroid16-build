#!/usr/bin/env bash
# VM .108 only. Adds the locally prepared API 36 ARM64 native bridge to a
# flattened rootfs. Does not install GApps or Magisk or modify AOSP out/.
set -euo pipefail
dest=/work/redroid16-lxc-rootfs
archive=/work/redroid16-deps/ndk-translation-api36-v5.tar
test "$(id -u)" -eq 0
test "$(findmnt -n -o TARGET /work)" = /work
test -d "$dest/system/apex/com.android.runtime"
test -f "$archive"
python3 - "$archive" "$dest" <<'PY'
import pathlib, sys, tarfile
archive, root = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
with tarfile.open(archive) as tar:
    members = tar.getmembers()
    required = {'system/lib64/libndk_translation.so',
                'system/bin/arm64/app_process64'}
    if not required.issubset({m.name for m in members}):
        raise SystemExit('Missing required API 36 ARM64 translation components')
    for member in members:
        path = pathlib.PurePosixPath(member.name)
        if path.is_absolute() or '..' in path.parts:
            raise SystemExit(f'Unsafe archive path: {member.name}')
        if not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
            raise SystemExit(f'Unexpected archive entry: {member.name}')
        if member.isfile() and (root / member.name).exists():
            raise SystemExit(f'Existing rootfs file: {member.name}')
print(f'Checking {len(members)} native bridge archive entries: no file overlaps')
PY
tar --no-same-owner -xf "$archive" -C "$dest"
# ART 16 requires a soname, not a path: use a regular ELF file for libnb.so.
test -f "$dest/system/lib64/libndk_translation.so"
test -x "$dest/system/bin/arm64/app_process64"
rm -f -- "$dest/system/lib64/libnb.so"
cp -- "$dest/system/lib64/libndk_translation.so" "$dest/system/lib64/libnb.so"
chmod 0644 "$dest/system/lib64/libnb.so"
echo 'Native bridge added. Start Android with ro.dalvik.vm.native.bridge=libnb.so.'
ls -lh "$dest/system/lib64/libndk_translation.so" "$dest/system/lib64/libnb.so"
