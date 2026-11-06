#!/usr/bin/env bash
# Run as root on VM .108 after 02-sync-aosp.sh has completed successfully.
set -euo pipefail
root=/work/aosp/source
deps=/work/redroid16-deps
patches="$deps/patches/redroid-patches/android-16.0.0_r2"
test "$(id -u)" -eq 0
test "$(findmnt -n -o TARGET /work)" = /work
test -d "$root/.repo"
test -d "$patches"
projects=(
    device/redroid
    device/redroid-prebuilts
    hardware/redroid/c2
    hardware/redroid/omx
    vendor/redroid
)
for project in "${projects[@]}"; do
    test -d "$deps/$project"
    if test -e "$root/$project"; then
        echo "Refusing to overwrite $root/$project" >&2
        exit 1
    fi
done
for project in "${projects[@]}"; do
    install -d -o aosp -g aosp "$(dirname "$root/$project")"
    cp -a "$deps/$project" "$root/$project"
    chown -R aosp:aosp "$root/$project"
    echo "Integrated $project"
done

# Official upstream's apply-patch.sh ignores git am failures; this script does not.
mapfile -t project_dirs < <(find "$patches" -type f -name '*.patch' -printf '%h\n' | sort -u)
for project_dir in "${project_dirs[@]}"; do
    project=${project_dir#"$patches"/}
    test -d "$root/$project"
    runuser -u aosp -- git -C "$root/$project" diff --quiet
    runuser -u aosp -- git -C "$root/$project" diff --cached --quiet
    mapfile -t patch_files < <(find "$project_dir" -maxdepth 1 -type f -name '*.patch' | sort)
    echo "Applying ${#patch_files[@]} Redroid patch(es) to $project"
    runuser -u aosp -- git -C "$root/$project" am -- "${patch_files[@]}"
done
echo 'Official Redroid 16 patches applied; flattened APEX changes NOT applied yet.'
