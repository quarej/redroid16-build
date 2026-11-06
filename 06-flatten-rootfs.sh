#!/usr/bin/env bash
# Run as root on VM .108 after a successful Redroid 16 build.
# VM loop devices are used only to READ APEX payloads, never on the PVE host.
set -euo pipefail
source_root=/work/aosp/source/out/target/product/redroid_x86_64
dest=/work/redroid16-lxc-rootfs
scratch=/work/redroid16-apex-extract
test "$(id -u)" -eq 0
test "$(findmnt -n -o TARGET /work)" = /work
test -d "$source_root/root" && test -d "$source_root/system/apex"
test -d "$source_root/vendor/apex"
test ! -e "$dest" && test ! -e "$scratch"
command -v rsync >/dev/null
command -v python3 >/dev/null
command -v mount >/dev/null

mkdir "$dest" "$scratch"
cleanup() {
    if mountpoint -q "$scratch/mnt"; then umount "$scratch/mnt"; fi
    if test -e "$scratch/payload.img"; then rm -f -- "$scratch/payload.img"; fi
}
trap cleanup EXIT
mkdir "$scratch/mnt"

rsync -aHAX --numeric-ids "$source_root/root/" "$dest/"
rsync -aHAX --numeric-ids "$source_root/system/" "$dest/system/"
rsync -aHAX --numeric-ids "$source_root/vendor/" "$dest/vendor/"

# Reject formats we don't know how to flatten. Check BEFORE removing any APEX.
python3 - "$dest" <<'PY'
import pathlib, sys, zipfile
root = pathlib.Path(sys.argv[1])
apexes = []
for partition in ('system', 'vendor'):
    apex_dir = root / partition / 'apex'
    for item in apex_dir.iterdir():
        if item.suffix == '.capex':
            raise SystemExit(f'Compressed APEX needs separate handling: {item}')
        if item.suffix != '.apex' or not item.is_file():
            raise SystemExit(f'Unexpected APEX entry: {item}')
        with zipfile.ZipFile(item) as archive:
            if 'apex_payload.img' not in archive.namelist():
                raise SystemExit(f'Missing payload: {item}')
            with archive.open('apex_payload.img') as payload:
                header = payload.read(1082)
            if header[1080:1082] != b'\x53\xef':
                raise SystemExit(f'Payload is not ext4: {item}')
        apexes.append(item)
print(f'Checked {len(apexes)} ext4 APEX payloads')
if not apexes:
    raise SystemExit('No APEX packages found')
PY

count=0
for partition in system vendor; do
    for apex in "$dest/$partition/apex/"*.apex; do
        test -f "$apex" || continue
        name=$(basename "$apex" .apex)
        target="$dest/$partition/apex/$name"
        test ! -e "$target"
        python3 - "$apex" "$scratch/payload.img" <<'PY'
import shutil, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as archive:
    with archive.open('apex_payload.img') as src, open(sys.argv[2], 'xb') as dst:
        shutil.copyfileobj(src, dst, 1024 * 1024)
PY
        mount -t ext4 -o ro,loop,noload "$scratch/payload.img" "$scratch/mnt"
        mkdir "$target"
        rsync -aHAX --numeric-ids "$scratch/mnt/" "$target/"
        test -f "$target/apex_manifest.pb" || {
            echo "Missing apex_manifest.pb in $name" >&2
            exit 1
        }
        umount "$scratch/mnt"
        rm -f -- "$scratch/payload.img" "$apex"
        count=$((count + 1))
        echo "Flattened $partition/$name"
    done
done
test "$count" -eq 35

python3 - "$dest/system/build.prop" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
old = 'ro.apex.updatable=true\n'
if s.count(old) != 1:
    raise SystemExit(f'Expected exactly one {old.strip()} in {p}')
p.write_text(s.replace(old, 'ro.apex.updatable=false\n', 1))
PY
if find "$dest/system/apex" "$dest/vendor/apex" -type f \( -name '*.apex' -o -name '*.capex' \) | grep -q .; then
    echo 'Refusing rootfs with packed APEX files' >&2
    exit 1
fi
echo "Flattened $count APEX packages into $dest"
df -hT /work
